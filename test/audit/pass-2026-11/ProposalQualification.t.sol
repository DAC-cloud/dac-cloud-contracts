// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Proposal qualification and the CAST_VETO_DEAL floor (M-09).
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.

import "forge-std/Test.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {ProposalParams, VotingConfig} from "../../../src/interfaces/Structs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealChallengeableProposal} from "../../../src/interfaces/IDealChallengeableProposal.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {MainToken} from "../../../src/kernel/tokens/MainToken.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";

/// Holds no main tokens at rest. Self-delegated once, so tokens that pass through it
/// inside one transaction carry `getVotes` for the duration of that transaction.
contract FlashChallenger {
    function prime(MainToken token) external {
        token.delegate(address(this));
    }

    function onLoan(DACCell dac, MainToken token, uint256 amount, uint256 dealId, uint256 proposalId)
        external
        returns (uint256 challengeId)
    {
        challengeId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAST_VETO_DEAL,
                target: address(0),
                i: bytes32(0),
                data: abi.encode(dealId, proposalId)
            })
        );
        token.transfer(msg.sender, amount); // repay inside the same call
    }
}

/// Stand-in for any atomic liquidity source (flash loan, flash swap).
contract FlashLender {
    function flash(
        MainToken token,
        FlashChallenger borrower,
        DACCell dac,
        uint256 amount,
        uint256 dealId,
        uint256 proposalId
    ) external returns (uint256 challengeId) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transfer(address(borrower), amount);
        challengeId = borrower.onLoan(dac, token, amount, dealId, proposalId);
        require(token.balanceOf(address(this)) >= balanceBefore, "loan not repaid");
    }
}

/// M-09. Opening a proposal is measured on past votes and puts them at stake: the
/// creator's qualifying votes (for a CAST_VETO_DEAL challenge at least 0.1% of the votable
/// supply) stay locked until the proposal's voting period is over.
contract ProposalQualification is DACTestBase {
    address internal agent1 = makeAddr("agent1");
    address internal agent2 = makeAddr("agent2");
    address internal challenger = makeAddr("challenger");
    address internal lenderEoa = makeAddr("lender");

    DealHandle internal handle;
    uint256 internal constant PERMIT_UNSTAKE_ID = 1;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);

        handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        vm.prank(agent2);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
    }

    function _openPermitUnstake() internal returns (address dealProposal) {
        // An agent asks to leave: PERMIT_UNSTAKE, always challengeable.
        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();
        dealProposal = Deal(handle.dealAddr).getProposal(PERMIT_UNSTAKE_ID);
        assertTrue(IDealChallengeableProposal(dealProposal).isChallengeable());
    }

    function _challenge() internal view returns (ProposalParams memory) {
        return ProposalParams({
            typ: DACManagementProposalType.CAST_VETO_DEAL,
            target: address(0),
            i: bytes32(0),
            data: abi.encode(handle.dealId, PERMIT_UNSTAKE_ID)
        });
    }

    function test_REG_M09_tokensHeldForOneCallDoNotQualify() public {
        // Atomic liquidity: 0.2% of supply sitting in a pool that never delegated.
        FlashLender lender = new FlashLender();
        FlashChallenger flashChallenger = new FlashChallenger();
        vm.prank(founder);
        mainToken.transfer(address(lender), 400_000e18);
        flashChallenger.prime(mainToken);
        vm.warp(block.timestamp + 1);

        address dealProposal = _openPermitUnstake();

        // One transaction: borrow 0.2% of supply, try to open the challenge, repay.
        vm.expectRevert(DACErrorsLib.InsufficientBalance.selector);
        lender.flash(mainToken, flashChallenger, dac, 400_000e18, handle.dealId, PERMIT_UNSTAKE_ID);

        assertEq(IDealChallengeableProposal(dealProposal).dacChallengeProposal(), address(0), "slot still free");

        // The deal's proposal runs its normal course.
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        IVoting(dealProposal).vote(true);
        vm.prank(agent2);
        IVoting(dealProposal).vote(true);
        Deal(handle.dealAddr).executeStakedAgentProposal(PERMIT_UNSTAKE_ID);
    }

    // Borrowing across a block does qualify: the votes were really held at the snapshot.
    // They then stay locked for the DAC's whole voting period, so the loan cannot be
    // returned in the next block. A challenge costs real exposure.
    function test_REG_M09_challengerKeepsItsQualifyingVotesLockedForTheVotingPeriod() public {
        vm.prank(founder);
        mainToken.transfer(lenderEoa, 400_000e18);
        vm.prank(challenger);
        mainToken.delegate(challenger);

        // block N: borrow 0.2% of the 200M votable supply
        vm.prank(lenderEoa);
        mainToken.transfer(challenger, 400_000e18);
        vm.warp(block.timestamp + 2);

        address dealProposal = _openPermitUnstake();

        // block N+1: open the challenge
        vm.prank(challenger);
        uint256 challengeId = dac.createManagementProposal(_challenge());
        assertEq(IDealChallengeableProposal(dealProposal).dacChallengeProposal(), dac.getProposalVoting(challengeId));

        uint256 floor = 200_000e18; // 0.1% of 200M
        (uint256 locked, uint256 until) = mainToken.lockedVotes(challenger);
        assertEq(locked, floor);
        assertEq(until, block.timestamp + dac.getVotingConfig().duration);

        // The loan cannot be repaid in full: the qualifying votes stay.
        vm.startPrank(challenger);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        mainToken.transfer(lenderEoa, 400_000e18);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        mainToken.delegate(lenderEoa);

        // Only what is above the floor is free to go.
        mainToken.transfer(lenderEoa, 200_000e18);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        mainToken.transfer(lenderEoa, 1);

        vm.warp(until + 1);
        mainToken.transfer(lenderEoa, 200_000e18);
        vm.stopPrank();
    }

    // With a non-zero `qualification` every proposal carries the same commitment.
    function test_REG_M09_creatorKeepsItsQualificationShareLockedForTheVotingPeriod() public {
        VotingConfig memory cfg = dac.getVotingConfig();
        cfg.qualification = MathLib.atScale(1); // 1% of the votable supply to open a proposal

        vm.startPrank(founder);
        uint256 id = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(id)).vote(true);
        dac.executeDACProposal(id);

        mainToken.transfer(challenger, 3_000_000e18); // 1.5%
        vm.stopPrank();
        vm.prank(challenger);
        mainToken.delegate(challenger);

        // Not yet: the votes must have been there at the previous second.
        vm.prank(challenger);
        vm.expectRevert(DACErrorsLib.InsufficientBalance.selector);
        dac.createManagementProposal(_offchain());

        vm.warp(block.timestamp + 1);
        vm.prank(challenger);
        dac.createManagementProposal(_offchain());

        (uint256 locked, uint256 until) = mainToken.lockedVotes(challenger);
        assertEq(locked, 2_000_000e18, "1% of the 200M votable supply");
        assertEq(until, block.timestamp + cfg.duration);

        vm.startPrank(challenger);
        vm.expectRevert(DACErrorsLib.VotesLocked.selector);
        mainToken.transfer(founder, 1_000_001e18);
        mainToken.transfer(founder, 1_000_000e18);

        // A second proposal needs the qualification again, and the creator still has it.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(DACErrorsLib.InsufficientBalance.selector); // 2M is not *more* than 1%
        dac.createManagementProposal(_offchain());
        vm.stopPrank();
    }

    function _offchain() internal pure returns (ProposalParams memory) {
        return ProposalParams({
            typ: DACManagementProposalType.APPROVE_OFFCHAIN_ACTION,
            target: address(0),
            i: 0,
            data: abi.encode(bytes4(0x12345678), bytes("memo"))
        });
    }
}
