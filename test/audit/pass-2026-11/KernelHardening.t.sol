// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Native governance, deal governance, staking, capital calls.
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.
//   test_NOTE_*    intended behaviour that audit.md documents as an operating note.
//   test_CONTROL_* the baseline a scenario is measured against.

import "forge-std/Test.sol";
import {DACTestBase, MockUSDC} from "../../base/DACTestBase.t.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {DACCellFactory} from "../../../src/kernel/factories/DACCellFactory.sol";
import {DACDeployment} from "../../../src/kernel/libraries/DACDeployment.sol";
import {Deal} from "../../../src/kernel/Deal.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {Proposal} from "../../../src/kernel/governance/Proposal.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IExecutableProposal} from "../../../src/interfaces/IExecutableProposal.sol";
import {IAssetController} from "../../../src/interfaces/IAssetController.sol";
import {DACConfig, CapitalCall, ProposalParams, VotingConfig} from "../../../src/interfaces/Structs.sol";
import {GovernanceLimits} from "../../../src/interfaces/GovernanceStructs.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {StakedAgent} from "../../../src/kernel/tokens/StakedAgent.sol";
import {MainToken} from "../../../src/kernel/tokens/MainToken.sol";
import {TreasuryDeal} from "../../../src/modules/core/deals/TreasuryDeal.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../../../src/kernel/governance/AbstractDealManagementProposals.sol";
import {CoreDealManagementType} from "../../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DealParams} from "../../../src/interfaces/Structs.sol";
import {Milestone} from "../../../src/modules/core/interfaces/Structs.sol";
import {MilestoneBasedEvaluator} from "../../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {CoreDealType, CoreEvaluatorType} from "../../../src/modules/core/CoreModuleDeals.sol";

contract KernelHardening is DACTestBase {
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address investor = makeAddr("investor");
    address holder2 = makeAddr("holder2");
    address outsider = makeAddr("outsider");
    address liquidator = makeAddr("liquidator");

    // Base caps a transaction at 2^24 gas (EIP-7825).
    uint256 internal constant BASE_TX_GAS_CAP = 16_777_216;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        onboardAgent(agent2);
        vm.warp(block.timestamp + 1);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _passAndExecute(ProposalParams memory params) internal returns (uint256 id) {
        vm.startPrank(founder);
        id = dac.createManagementProposal(params);
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(id)).vote(true);
        dac.executeDACProposal(id);
        vm.stopPrank();
    }

    function _capitalCall(address recipient, uint256 tokenAmount, uint256 cashAmount, uint256 expiry)
        internal
        view
        returns (ProposalParams memory)
    {
        return ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: recipient,
            i: bytes32(tokenAmount),
            data: abi.encode(address(usdc), cashAmount, expiry)
        });
    }

    function _stakeAndDelegate(address agent, address dealCell, uint256 amount) internal {
        vm.startPrank(agent);
        agentToken.stakeToDeal(dealCell, amount);
        StakedAgent(IDealCell(dealCell).stakeToken()).delegate(agent);
        vm.stopPrank();
    }

    function _approveDeal(DealHandle memory handle) internal {
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
    }

    function _voteDeal(address dealAddr, uint256 proposalId, address voter, bool support) internal {
        address proposal = Deal(dealAddr).getProposal(proposalId);
        vm.prank(voter);
        IVoting(proposal).vote(support);
    }

    function _enableVeto(DealHandle memory handle) internal {
        vm.prank(agent1);
        uint256 pid = Deal(handle.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: AbstractDealManagementType.ENABLE_VETO_RIGHT, target: address(0), i: 0, data: bytes("")
                })
            );
        vm.warp(block.timestamp + 1);
        _voteDeal(handle.dealAddr, pid, agent1, true);
        _voteDeal(handle.dealAddr, pid, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);
        assertTrue(IDealCell(handle.dealCell).allowDACVeto());
        vm.warp(block.timestamp + 1);
    }

    // The most permissive voting config the kernel accepts: every threshold at its floor.
    function _laxConfig() internal pure returns (VotingConfig memory) {
        return VotingConfig({
            quorumPercent: GovernanceLimits.MIN_PERCENT,
            blockingPercent: 0,
            highQuorumPercent: GovernanceLimits.MIN_PERCENT,
            duration: 1,
            qualification: 0,
            executionValidityDuration: 365 days
        });
    }

    // Treasury deal whose single milestone pays nothing and slashes 100% when missed
    // (the shared fixture's constant reward curve converts 100% and closes the deal
    // before any slash is applied, which hides slashing behaviour).
    function _createSlashingDeal(address agent) internal returns (DealHandle memory handle) {
        return _createCurveDeal(agent, 0, 1e18);
    }

    function _createCurveDeal(address agent, int256 rewardCoeff, int256 penaltyCoeff)
        internal
        returns (DealHandle memory handle)
    {
        vm.recordLogs();
        vm.startPrank(agent);

        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 1 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0,
            excludePrincipal: false
        });
        milestones[0].rewardCurve[0] = rewardCoeff;
        milestones[0].penaltyCurve[0] = penaltyCoeff;

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Slashing Deal",
            description: "milestone with a real penalty",
            linkHash: "0x00",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        (handle.dealId, handle.dealCell, handle.dealAddr, handle.evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(params);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }

    // ------------------------------------------------------------------
    // H-02. One past timepoint for a proposal's weights and for its base.
    //    A proposal reads vote weights and the votable supply at the second before its
    //    creation: nothing issued in the creation second, before or after the proposal,
    //    can vote on it.
    // ------------------------------------------------------------------
    function test_REG_H02_sameSecondMint_cannotVoteOnTheProposal() public {
        // Governance approves a capital call: investor may buy 150M tokens (0.75x of
        // the 200M votable supply). Post-money the investor owns 42.86%.
        uint256 callId = _passAndExecute(_capitalCall(investor, 150_000_000e18, 15_000e6, block.timestamp + 30 days));

        // The investor holds one wei of main token and self-delegates, which is all
        // `createManagementProposal` asks for at qualification 0.
        vm.prank(founder);
        mainToken.transfer(investor, 1);
        vm.prank(investor);
        mainToken.delegate(investor);
        usdc.mint(investor, 15_000e6);

        vm.warp(block.timestamp + 10);
        address controller = dac.getAssetController();

        // --- one block / one timestamp -------------------------------------------------
        vm.startPrank(investor);
        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG,
                target: address(0),
                i: 0,
                data: abi.encode(_laxConfig())
            })
        );
        usdc.approve(controller, 15_000e6);
        dac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: callId,
                tokenRecipient: investor,
                tokenAmount: 150_000_000e18,
                cashAmount: 15_000e6
            })
        );
        vm.stopPrank();
        // -------------------------------------------------------------------------------

        Proposal p = Proposal(dac.getProposalVoting(pid));
        assertEq(p.snapshotTime(), block.timestamp - 1, "weights are read before the creation second");
        assertEq(p.totalVotingPower(), 200_000_000e18, "base is the votable supply at that same second");

        vm.warp(block.timestamp + 1);

        // The 150M minted in the creation second carry no weight on this proposal.
        vm.startPrank(investor);
        p.vote(true);
        assertEq(p.yesVotes(), 1, "only what was held before the creation second votes");
        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        dac.executeDACProposal(pid);
        vm.stopPrank();

        assertEq(dac.getVotingConfig().highQuorumPercent, MathLib.atScale(75), "config untouched");
    }

    // Same second, other order: the mint first, the proposal after it.
    function test_REG_H02_mintThenProposeInOneSecond_votesWithPreMintWeight() public {
        uint256 callId = _passAndExecute(_capitalCall(investor, 150_000_000e18, 15_000e6, block.timestamp + 30 days));
        vm.prank(founder);
        mainToken.transfer(investor, 1);
        vm.prank(investor);
        mainToken.delegate(investor);
        usdc.mint(investor, 15_000e6);
        vm.warp(block.timestamp + 10);
        address controller = dac.getAssetController();

        vm.startPrank(investor);
        usdc.approve(controller, 15_000e6);
        dac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: callId,
                tokenRecipient: investor,
                tokenAmount: 150_000_000e18,
                cashAmount: 15_000e6
            })
        );
        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG,
                target: address(0),
                i: 0,
                data: abi.encode(_laxConfig())
            })
        );
        vm.stopPrank();

        Proposal p = Proposal(dac.getProposalVoting(pid));
        assertEq(p.totalVotingPower(), 200_000_000e18, "the mint is not in the base");

        vm.warp(block.timestamp + 1);
        vm.prank(investor);
        p.vote(true);
        assertEq(p.yesVotes(), 1, "and not in the weight either");
    }

    // Reading weights at a past second does not open voting any earlier: a proposal cannot
    // be created and voted on (and so resolved and executed) in one transaction.
    function test_REG_H02_votingOpensTheSecondAfterCreation() public {
        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.APPROVE_OFFCHAIN_ACTION,
                target: address(0),
                i: 0,
                data: abi.encode(bytes4(0x12345678), bytes("memo"))
            })
        );
        Proposal p = Proposal(dac.getProposalVoting(pid));

        vm.expectRevert(DACErrorsLib.VotingNotStarted.selector);
        p.vote(true);

        vm.warp(block.timestamp + 1);
        p.vote(true);
        dac.executeDACProposal(pid);
        vm.stopPrank();
        assertTrue(p.isExecuted());
    }

    // Control: tokens held before the snapshot vote with their real share, which is not enough.
    function test_CONTROL_H02_mintBeforeProposal_cannotPassHighQuorum() public {
        uint256 callId = _passAndExecute(_capitalCall(investor, 150_000_000e18, 15_000e6, block.timestamp + 30 days));
        vm.prank(investor);
        mainToken.delegate(investor);
        usdc.mint(investor, 15_000e6);
        address controller = dac.getAssetController();

        vm.startPrank(investor);
        usdc.approve(controller, 15_000e6);
        dac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: callId,
                tokenRecipient: investor,
                tokenAmount: 150_000_000e18,
                cashAmount: 15_000e6
            })
        );
        vm.warp(block.timestamp + 10);

        uint256 pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG,
                target: address(0),
                i: 0,
                data: abi.encode(_laxConfig())
            })
        );
        Proposal p = Proposal(dac.getProposalVoting(pid));
        assertEq(p.totalVotingPower(), 350_000_000e18);

        vm.warp(block.timestamp + 1);
        p.vote(true);
        assertEq(p.yesVotes(), 150_000_000e18); // 42.86% of 350M, below the 75% high quorum
        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    // H-02 at deal level. Stake added in the second a deal proposal is created does not
    // vote on it either.
    function test_REG_H02_sameSecondStake_cannotVoteOnTheDealProposal() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, false);
        _stakeAndDelegate(agent2, handle.dealCell, 1);
        vm.warp(block.timestamp + 10);

        VotingConfig memory before = Deal(handle.dealAddr).votingConfig();

        // one timestamp: the proposal, then the stake
        vm.startPrank(agent2);
        uint256 pid = Deal(handle.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: AbstractDealManagementType.UPDATE_VOTING_CONFIG,
                    target: address(0),
                    i: 0,
                    data: abi.encode(_laxConfig())
                })
            );
        agentToken.stakeToDeal(handle.dealCell, 16_000);
        vm.stopPrank();

        Proposal p = Proposal(Deal(handle.dealAddr).getProposal(pid));
        assertEq(p.totalVotingPower(), 20_001, "base is the stake supply before the creation second");

        vm.warp(block.timestamp + 1);
        _voteDeal(handle.dealAddr, pid, agent2, true);
        assertEq(p.yesVotes(), 1, "the 16_000 staked in the creation second do not vote");

        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);

        assertEq(Deal(handle.dealAddr).votingConfig().highQuorumPercent, before.highQuorumPercent);
    }

    // ------------------------------------------------------------------
    // L-13. Voting configs are sanity-checked wherever they are set: thresholds have a
    //    0.1% floor, "high" is never below the default quorum.
    // ------------------------------------------------------------------
    function test_REG_L13_votingConfigSanityBounds() public {
        VotingConfig memory cfg = _laxConfig();

        cfg.quorumPercent = 50; // a unit mistake: 50 wei of 1e18, not 50%
        _expectInvalidConfig(cfg);

        cfg = _laxConfig();
        cfg.highQuorumPercent = 1;
        _expectInvalidConfig(cfg);

        cfg = _laxConfig();
        cfg.quorumPercent = MathLib.atScale(60);
        cfg.highQuorumPercent = MathLib.atScale(50); // "high" easier than the default
        _expectInvalidConfig(cfg);

        cfg = _laxConfig();
        cfg.blockingPercent = 1; // non-zero and below the floor
        _expectInvalidConfig(cfg);

        cfg = _laxConfig();
        cfg.executionValidityDuration = 0;
        _expectInvalidConfig(cfg);

        // No relation between blocking and quorum is imposed: a low quorum with a larger
        // objection threshold (optimistic governance) is accepted.
        cfg = _laxConfig();
        cfg.quorumPercent = MathLib.atScale(5);
        cfg.highQuorumPercent = MathLib.atScale(60);
        cfg.blockingPercent = MathLib.atScale(20);
        vm.prank(founder);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
            })
        );
    }

    function _expectInvalidConfig(VotingConfig memory cfg) internal {
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.InvalidVotingConfig.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_VOTING_CONFIG, target: address(0), i: 0, data: abi.encode(cfg)
            })
        );
    }

    // ------------------------------------------------------------------
    // M-01 (operating note). A deal proposal executes as soon as it resolves. A DAC
    //    challenge needs a proposal that is still pending, so it cannot attach to one
    //    that the deal's stakers resolve and execute within a block. Deals that need a
    //    reaction window get it from their module (an execution delay), not from the kernel.
    // ------------------------------------------------------------------
    function test_NOTE_M01_dealProposalExecutesOnResolution_noKernelChallengeWindow() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);
        _enableVeto(handle);

        address treasury = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(treasury), 10_000);

        // second T: create
        vm.prank(agent1);
        uint256 pid = Deal(handle.dealAddr)
            .createStakedAgentProposal(
                ProposalParams({
                    typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                    target: address(usdc),
                    i: 0,
                    data: abi.encode(agent1, uint160(10_000))
                })
            );

        // second T+1: vote, resolve, execute, in one block
        vm.warp(block.timestamp + 1);
        _voteDeal(handle.dealAddr, pid, agent1, true);
        _voteDeal(handle.dealAddr, pid, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(pid);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(agent1), 10_000);

        // A DAC challenge opened one block later finds nothing pending.
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.ProposalAlreadyExecuted.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAST_VETO_DEAL,
                target: address(0),
                i: 0,
                data: abi.encode(handle.dealId, pid)
            })
        );
    }

    // M-01 (operating note, consequence). The same holds for PERMIT_UNSTAKE: a staker
    // majority can leave ahead of an evaluation. Stake is at risk for as long as the
    // deal's own stakers keep it there; `minimalStake` and the whitelist are the tools
    // that keep co-stakers meaningful.
    function test_NOTE_M01_stakerMajorityCanUnstakeAheadOfAnEvaluation() public {
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 100_000); // the real stake
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 1); // dust co-staker
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);

        // The milestone (10_000e6 returned by +1 day) will be missed. Just before it:
        vm.warp(block.timestamp + 1 days - 100);

        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake(); // opens PERMIT_UNSTAKE (id 1)
        vm.warp(block.timestamp + 1);
        _voteDeal(handle.dealAddr, 1, agent1, true); // 99.999% of stake: high quorum alone
        Deal(handle.dealAddr).executeStakedAgentProposal(1);

        assertEq(agentToken.balanceOf(agent1), 100_000, "full stake recovered");

        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.ProposalAlreadyExecuted.selector);
        dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAST_VETO_DEAL,
                target: address(0),
                i: 0,
                data: abi.encode(handle.dealId, uint256(1))
            })
        );

        // The failing evaluation slashes what is left in the deal.
        vm.warp(block.timestamp + 16 days);
        uint256 supplyBefore = agentToken.totalSupply();
        vm.prank(founder);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(supplyBefore - agentToken.totalSupply(), 1, "only the remaining stake was slashed");
        assertEq(agentToken.balanceOf(agent1), 100_000);
    }

    // Control: the same deal without the exit loses the whole stake.
    function test_CONTROL_M01_noExit_fullStakeSlashed() public {
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 100_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 16 days);

        uint256 supplyBefore = agentToken.totalSupply();
        vm.prank(founder);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(supplyBefore - agentToken.totalSupply(), 100_000);
    }

    // ------------------------------------------------------------------
    // M-02. Timestamps follow the configured durations. A proposal that passes by
    //    timeout is stamped with the end of voting, whoever observes it first and
    //    whenever: its execution window cannot be parked.
    // ------------------------------------------------------------------
    function _timeoutPassProposal() internal returns (uint256 pid, Proposal p) {
        // 30% of votes sit with a passive holder, so the founder's 70% cannot resolve a
        // blocking-type proposal early (that needs yes >= total - blocking = 75%).
        vm.prank(founder);
        mainToken.transfer(holder2, 60_000_000e18);
        vm.warp(block.timestamp + 1);

        vm.startPrank(founder);
        pid = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.APPROVE_OFFCHAIN_ACTION,
                target: address(0),
                i: 0,
                data: abi.encode(bytes4(0x12345678), bytes("sign the lease"))
            })
        );
        p = Proposal(dac.getProposalVoting(pid));
        vm.warp(block.timestamp + 1);
        p.vote(true); // 70% yes: passes at endTime only
        vm.stopPrank();

        assertFalse(p.isResolved());
    }

    function test_REG_M02_timeoutPass_expiresOnScheduleEvenIfNeverTouched() public {
        (uint256 pid, Proposal p) = _timeoutPassProposal();
        uint256 end = p.endTime();
        assertEq(dac.getVotingConfig().executionValidityDuration, 1 days);

        // Two years after the vote ended, nobody having touched the proposal...
        vm.warp(end + 730 days);

        // ...it is long past its execution window.
        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.ProposalNotExecutable.selector);
        dac.executeDACProposal(pid);

        // The first observation records the end of voting, not its own time.
        assertTrue(p.isResolved());
        assertEq(p.resolutionTime(), end);
        assertEq(p.executionDeadline(), end + 1 days);
        assertTrue(p.isExecutionExpired());
    }

    // Control: inside the window the proposal executes, first touched or not.
    function test_CONTROL_M02_timeoutPass_executableInsideItsWindow() public {
        (uint256 pid, Proposal p) = _timeoutPassProposal();
        uint256 end = p.endTime();

        vm.warp(end + 1 days); // last second of the window, never poked before
        vm.prank(outsider);
        dac.executeDACProposal(pid);
        assertTrue(p.isExecuted());
        assertEq(p.resolutionTime(), end);
    }

    // ------------------------------------------------------------------
    // M-03. A capital call is an offer at a fixed price with a stated expiry.
    // ------------------------------------------------------------------
    function test_REG_M03_capitalCall_cannotBeFulfilledAfterItsExpiry() public {
        uint256 expiry = block.timestamp + 30 days;
        uint256 callId = _passAndExecute(_capitalCall(investor, 10_000_000e18, 1_000e6, expiry));

        CapitalCall memory call = CapitalCall({
            treasuryToken: address(usdc),
            nonce: callId,
            tokenRecipient: investor,
            tokenAmount: 10_000_000e18,
            cashAmount: 1_000e6
        });
        bytes32 callHash = keccak256(abi.encode(call));
        address controller = dac.getAssetController();

        assertEq(dac.getCapitalCall(callHash).tokenAmount, 10_000_000e18);
        assertEq(IAssetController(controller).getCapitalCallExpiry(callHash), expiry);

        usdc.mint(investor, 5_000e6);
        vm.prank(investor);
        usdc.approve(controller, type(uint256).max);

        // One second past the expiry the offer is gone, for the recipient and for anyone else.
        vm.warp(expiry + 1);
        vm.expectRevert(DACErrorsLib.CapitalCallExpired.selector);
        dac.getCapitalCall(callHash);

        vm.prank(investor);
        vm.expectRevert(DACErrorsLib.CapitalCallExpired.selector);
        dac.fulfillCapitalCall(call);

        assertEq(mainToken.balanceOf(investor), 0);
        assertEq(usdc.balanceOf(investor), 5_000e6);
    }

    function test_REG_M03_capitalCallProposal_mustStateAFutureExpiry() public {
        vm.startPrank(founder);

        // Zero ("never") is reserved for a DAC's root call.
        vm.expectRevert(DACErrorsLib.CapitalCallExpired.selector);
        dac.createManagementProposal(_capitalCall(investor, 1e18, 1, 0));

        vm.expectRevert(DACErrorsLib.CapitalCallExpired.selector);
        dac.createManagementProposal(_capitalCall(investor, 1e18, 1, block.timestamp));

        // A proposal executed after the expiry it carries creates nothing.
        uint256 pid = dac.createManagementProposal(_capitalCall(investor, 1e18, 1, block.timestamp + 2));
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(pid)).vote(true);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(DACErrorsLib.CapitalCallExpired.selector);
        dac.executeDACProposal(pid);

        vm.stopPrank();
    }

    // M-03 (operating note). Until it expires, an open call is filled by whoever sends the
    // transaction, with the recipient's funds: a recipient approves the asset controller
    // only when it means to pay.
    function test_NOTE_M03_openCall_anyoneCanTriggerItAgainstTheRecipientsAllowance() public {
        uint256 callId = _passAndExecute(_capitalCall(investor, 10_000_000e18, 1_000e6, block.timestamp + 30 days));

        usdc.mint(investor, 5_000e6);
        address controller = dac.getAssetController();
        vm.prank(investor);
        usdc.approve(controller, type(uint256).max);

        vm.warp(block.timestamp + 29 days);
        vm.prank(outsider);
        dac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: callId,
                tokenRecipient: investor,
                tokenAmount: 10_000_000e18,
                cashAmount: 1_000e6
            })
        );

        assertEq(mainToken.balanceOf(investor), 10_000_000e18);
        assertEq(usdc.balanceOf(investor), 4_000e6);
    }

    // ------------------------------------------------------------------
    // L-03. A capital call issues votable tokens to a chosen recipient at a chosen
    //    price: it needs the high quorum, like a mint.
    // ------------------------------------------------------------------
    function test_REG_L03_capitalCall_needsTheHighQuorum() public {
        vm.prank(founder);
        mainToken.transfer(holder2, 60_000_000e18);
        vm.warp(block.timestamp + 1);

        vm.startPrank(founder);
        uint256 pid = dac.createManagementProposal(_capitalCall(investor, 1e18, 1, block.timestamp + 30 days));
        Proposal p = Proposal(dac.getProposalVoting(pid));
        assertEq(p.quorum(), 150_000_000e18, "75% of the votable supply");
        assertEq(p.blockingQuorum(), 50_000_000e18, "and still blockable by 25%");

        vm.warp(block.timestamp + 1);
        p.vote(true); // 70%
        vm.warp(p.endTime() + 1);
        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        dac.executeDACProposal(pid);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // M-06. Who may evaluate a deal, and when. Until the evaluation deadline: whoever
    //    holds stake in that deal. After it: any main-token holder or agent of the DAC.
    // ------------------------------------------------------------------
    function test_REG_M06_beforeTheDeadline_onlyTheDealsOwnStakersEvaluate() public {
        DealHandle memory handle = _createCurveDeal(agent1, 1e18, 0);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 100_000); // stakes everything it has
        _approveDeal(handle);
        vm.warp(block.timestamp + 2 days); // milestone date passed, evaluationDeadline (15d) not

        assertEq(agentToken.balanceOf(agent1), 0);
        assertEq(mainToken.balanceOf(agent1), 0);
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        assertEq(stake.balanceOf(agent2), 0);

        // An agent of the DAC with no stake in this deal cannot evaluate it yet...
        vm.prank(agent2);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        // ...nor can a main-token holder.
        vm.prank(founder);
        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        // The deal's own agent can, with no idle AgentToken and no main token at all.
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), MathLib.SCALE);
    }

    function test_REG_M06_afterTheDeadline_holdersAndAgentsStepIn_outsidersDoNot() public {
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 100_000);
        _approveDeal(handle);
        vm.warp(IDealCell(handle.dealCell).evaluationDeadline() + 1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        vm.prank(agent2); // idle AgentToken, no stake in the deal
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(stake.balanceOf(agent1), 0, "missed milestone slashed");
    }

    // ------------------------------------------------------------------
    // L-01. A DAC address commits to its deployer: nobody else can take the address a
    //    deployer computed for a salt.
    // ------------------------------------------------------------------
    function test_REG_L01_dacAddressIsBoundToTheDeployer() public {
        bytes32 salt = keccak256("acme-dac");
        MockUSDC otherToken = new MockUSDC();

        DACConfig memory cfg = _acmeConfig(founder, address(usdc), 10_000e6);
        // Same salt, same name and description, somebody else's founder and token.
        DACConfig memory otherCfg = _acmeConfig(outsider, address(otherToken), 0);

        vm.prank(outsider);
        (address other,,) = dacFactory.deployDAC(otherCfg, salt, address(0));

        address predicted = DACDeployment.predictDACAddress(
            dacFactory.deploymentSalt(founder, salt),
            address(dacFactory),
            DACCellFactory(dacFactory.cellFactory()).referenceImpl(),
            dacFactory.cellFactory(),
            cfg.name,
            cfg.description,
            dacFactory.governanceFactory()
        );

        vm.prank(founder);
        (address mine,,) = dacFactory.deployDAC(cfg, salt, address(0));

        assertEq(mine, predicted, "the deployer gets the address it computed");
        assertTrue(mine != other);

        CapitalCall memory root = CapitalCall({
            treasuryToken: address(usdc),
            nonce: 0,
            tokenRecipient: founder,
            tokenAmount: 100_000e18,
            cashAmount: 10_000e6
        });
        assertEq(DACCell(mine).getCapitalCall(keccak256(abi.encode(root))).tokenAmount, 100_000e18);
    }

    function _acmeConfig(address founder_, address treasuryToken, uint256 commitment)
        internal
        pure
        returns (DACConfig memory)
    {
        return DACConfig({
            symbol: "ACME",
            name: "Acme DAC",
            description: "the real one",
            mainTokenMaxSupply: 1_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder_,
            founderAllocation: 100_000e18,
            treasuryToken: treasuryToken,
            founderCommitment: commitment,
            dividendsEnabled: false
        });
    }

    // ------------------------------------------------------------------
    // H-03. A stake is never zero, and a deal's holder list is capped, so the loops
    //    that slash and allocate always fit in one transaction.
    // ------------------------------------------------------------------
    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0xA11CE00000 + i));
    }

    // agent1 plus `n - 1` further agents, each with a real stake.
    function _fillHolders(DealHandle memory handle, uint256 n, uint256 stakeEach) internal {
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, stakeEach);
        for (uint256 i = 1; i < n; i++) {
            address h = _holder(i);
            vm.prank(address(dac));
            agentToken.mint(h, stakeEach);
            vm.prank(agent1);
            IDealCell(handle.dealCell).invite(h, false);
            vm.prank(h);
            agentToken.stakeToDeal(handle.dealCell, stakeEach);
        }
    }

    function _cool(DealHandle memory handle) internal {
        vm.cool(handle.dealCell);
        vm.cool(IDealCell(handle.dealCell).stakeToken());
        vm.cool(address(agentToken));
        vm.cool(dealManager);
    }

    function test_REG_H03_zeroStakeIsRejected() public {
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 50_000);

        address sybil = makeAddr("sybil"); // holds no AgentToken at all
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(sybil, false);

        vm.prank(sybil);
        vm.expectRevert(DACErrorsLib.ZeroStake.selector);
        agentToken.stakeToDeal(handle.dealCell, 0);

        // ...and an existing holder cannot add zero either.
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.ZeroStake.selector);
        agentToken.stakeToDeal(handle.dealCell, 0);

        assertEq(IDealCell(handle.dealCell).holdersCount(), 1);
    }

    function test_REG_H03_holderListIsCapped_liquidatorIsExempt() public {
        uint256 cap = GovernanceLimits.MAX_DEAL_HOLDERS;
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _fillHolders(handle, cap, 1_000);
        assertEq(IDealCell(handle.dealCell).holdersCount(), cap);

        // One more distinct staker does not fit, whatever the deal's own agentsLimit says.
        address extra = _holder(cap);
        vm.prank(address(dac));
        agentToken.mint(extra, 1_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(extra, false);
        vm.prank(extra);
        vm.expectRevert(DACErrorsLib.HoldersLimitReached.selector);
        agentToken.stakeToDeal(handle.dealCell, 1_000);

        // A holder already on the list can still add to its stake.
        vm.prank(_holder(1));
        vm.expectRevert(); // it staked its whole balance; top it up first
        agentToken.stakeToDeal(handle.dealCell, 1);
        vm.prank(address(dac));
        agentToken.mint(_holder(1), 1);
        vm.prank(_holder(1));
        agentToken.stakeToDeal(handle.dealCell, 1);

        // Slash everything and close; governance can then still appoint a liquidator,
        // which joins over the cap.
        _approveDeal(handle);
        vm.warp(block.timestamp + 16 days);
        vm.prank(founder);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertTrue(IDealCell(handle.dealCell).isClosed());

        _passAndExecute(
            ProposalParams({
                typ: DACManagementProposalType.RECOVER_DEAL,
                target: liquidator,
                i: bytes32(uint256(8_000)),
                data: abi.encode(handle.dealId)
            })
        );
        assertEq(StakedAgent(IDealCell(handle.dealCell).stakeToken()).balanceOf(liquidator), 8_000);
        assertEq(IDealCell(handle.dealCell).holdersCount(), cap + 1);
    }

    // A full holder list, every holder with a live stake, slashed 100% and closed in one
    // evaluation with cold storage: inside the Base transaction gas cap with room to spare.
    function test_REG_H03_fullHolderList_slashAndCloseFitInABaseTransaction() public {
        DealHandle memory handle = _createSlashingDeal(agent1);
        vm.warp(block.timestamp + 1);
        _fillHolders(handle, GovernanceLimits.MAX_DEAL_HOLDERS, 1_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 16 days);

        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        _cool(handle);
        vm.prank(founder);
        uint256 g = gasleft();
        DealManager(dealManager).evaluateDeal{gas: BASE_TX_GAS_CAP}(handle.dealId, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("slash + close, 100 live holders, gas", used);

        assertEq(stake.totalSupply(), 0, "everything slashed");
        assertTrue(IDealCell(handle.dealCell).isClosed(), "and the deal closed");
        assertLt(used, BASE_TX_GAS_CAP / 2, "under half of the transaction cap");
    }

    // The paying branch at a full list.
    function test_REG_H03_fullHolderList_rewardAllocationFitsInABaseTransaction() public {
        DealHandle memory handle = _createCurveDeal(agent1, 1e18, 0);
        vm.warp(block.timestamp + 1);
        _fillHolders(handle, GovernanceLimits.MAX_DEAL_HOLDERS, 1_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 16 days);

        _cool(handle);
        vm.prank(founder);
        uint256 g = gasleft();
        DealManager(dealManager).evaluateDeal{gas: BASE_TX_GAS_CAP}(handle.dealId, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("convert + close, 100 live holders, gas", used);

        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), MathLib.SCALE, "rewards converted");
        assertLt(used, BASE_TX_GAS_CAP / 2);
    }
}
