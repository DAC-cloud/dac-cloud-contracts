// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DealParams, ProposalParams} from "../src/interfaces/Structs.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {IDACCell} from "../src/interfaces/IDACCell.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {AbstractDealManagementType} from "../src/kernel/governance/AbstractDealManagementProposals.sol";
import {DealManagementProposal} from "../src/kernel/governance/DealManagementProposal.sol";
import {CoreDealManagementType} from "../src/modules/core/governance/CoreDealManagementProposals.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {Permit2Treasury} from "../src/modules/core/deals/Permit2Treasury.sol";
import {CoreDealType, CoreEvaluatorType} from "../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {RevenueBasedEvaluator} from "../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {Milestone, TreasurySpendAllowance, RevenueSchedule} from "../src/modules/core/interfaces/Structs.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {IDealManagerAdapter} from "../src/kernel/interfaces/IDealManagerAdapter.sol";
import {DealState} from "../src/kernel/interfaces/Structs.sol";
import {IPermit2} from "../src/lib/IPermit2.sol";

contract MockPermit2 {
    function approve(address, address, uint160, uint48) external pure {}
    function transferFrom(address, address, uint160, address) external pure {}
    function permitTransferFrom(
        IPermit2.PermitTransferFrom memory,
        IPermit2.SignatureTransferDetails calldata,
        address,
        bytes calldata
    ) external pure {}
}

contract MockVotesToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Mock Governance Token", "MGOV") ERC20Permit("Mock Governance Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

contract ZeroFirstApproveToken is ERC20 {
    constructor() ERC20("Zero First Token", "ZFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(amount == 0 || allowance(msg.sender, spender) == 0, "zero-first");
        return super.approve(spender, amount);
    }
}

contract DealGovernanceFlowTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    MockVotesToken public govToken;
    ZeroFirstApproveToken public zeroFirstToken;

    function setUp() public {
        setUpBase();
        vm.etch(permit2, address(new MockPermit2()).code);
        govToken = new MockVotesToken();
        zeroFirstToken = new ZeroFirstApproveToken();

        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function test_requestTranche_createsDACProposalAndFundsTreasury() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        assertEq(IDealCell(handle.dealCell).getInvestedCapital(address(usdc)), 10_000);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        uint256 trancheRequestId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(usdc),
                i: bytes32(uint256(5_000)),
                data: abi.encode(uint256(0))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, trancheRequestId, agent1, true);
        _voteDealProposal(handle.dealAddr, trancheRequestId, agent2, true);

        vm.recordLogs();
        Deal(handle.dealAddr).executeStakedAgentProposal(trancheRequestId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 dacProposalId = _findProposalIdFromData(
            logs,
            keccak256("TrancheCreated(address,uint256,uint256,uint256)")
        );

        assertEq(IDealCell(handle.dealCell).fundingTranche(trancheRequestId).amount, 5_000);

        vm.warp(block.timestamp + 1);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(IDealCell(handle.dealCell).getInvestedCapital(address(usdc)), 15_000);
        assertEq(usdc.balanceOf(treasuryAddr), 15_000);
    }

    function test_createTreasuryDeal_emitsRelatedTreasuryContract() public {
        (DealHandle memory handle, Vm.Log[] memory logs) = _createTreasuryDealWithLogs(agent1);

        (
            uint256 loggedId,
            address relatedContract,
            address loggedDeal,
            address loggedDealCell,
            bytes32 role,
            bool controlled,
            bool managed
        ) = _findRelatedContract(logs);

        assertEq(loggedId, handle.dealId);
        assertEq(relatedContract, TreasuryDeal(handle.dealAddr).managedEntity());
        assertEq(loggedDeal, handle.dealAddr);
        assertEq(loggedDealCell, handle.dealCell);
        assertEq(role, bytes32("TREASURY"));
        assertTrue(controlled);
        assertTrue(managed);
    }

    function test_permitUnstake_releasesAgentPrincipalAfterApproval() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);

        vm.prank(agent1);
        IDealCell(handle.dealCell).unstake();

        uint256 permitUnstakeId = 1;

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, permitUnstakeId, agent1, true);
        _voteDealProposal(handle.dealAddr, permitUnstakeId, agent2, true);

        vm.warp(block.timestamp + 31 days);

        Deal(handle.dealAddr).executeStakedAgentProposal(permitUnstakeId);

        assertEq(StakedAgent(IDealCell(handle.dealCell).stakeToken()).balanceOf(agent1), 0);
        assertEq(agentToken.balanceOf(agent1), 100_000);
    }

    function test_toggleEarlyReturns_thenReturnCapitalToDAC() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();

        vm.startPrank(agent1);
        uint256 toggleProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
                target: address(0),
                i: 0,
                data: abi.encode(true)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, toggleProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, toggleProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(toggleProposalId);

        assertTrue(IDealCell(handle.dealCell).allowEarlyReturns());

        uint256 dacBalanceBefore = usdc.balanceOf(address(dac));

        vm.startPrank(agent1);
        uint256 returnProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_CAPITAL_TO_DAC,
                target: address(usdc),
                i: 0,
                data: abi.encode(uint256(4_000))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, returnProposalId, agent1, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(returnProposalId);

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), 4_000);
        assertEq(usdc.balanceOf(address(dac)), dacBalanceBefore + 4_000);
        assertEq(usdc.balanceOf(treasuryAddr), 6_000);
    }

    function test_toggleWhitelist_emitsEvent() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_WHITELIST,
                target: address(0),
                i: 0,
                data: abi.encode(false)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);

        vm.expectEmit(true, false, false, true, handle.dealCell);
        emit DACEventsLib.WhitelistToggled(handle.dealId, false);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.NotWhitelistDeal.selector);
        IDealCell(handle.dealCell).invite(makeAddr("late-invitee"), true);
    }

    function test_addEvaluator_requiresDACAndStakedAgentApproval() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();

        RevenueSchedule memory schedule = RevenueSchedule({
            token: address(usdc),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25),
            graceCycles: 1,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        schedule.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        schedule.requirementCurveCoeffs[1] = 0;
        schedule.curveCoeffs[0] = 0;
        schedule.curveCoeffs[1] = 1e18;

        bytes memory evaluatorConfig = abi.encode(
            CoreEvaluatorType.REVENUE_EVALUATOR,
            abi.encode(
                RevenueBasedEvaluator.Config({
                    rewardShare: MathLib.atScale(20),
                    schedule: schedule
                })
            )
        );

        vm.startPrank(founder);
        uint256 dacProposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.ADD_EVALUATOR,
                target: address(0),
                i: 0,
                data: abi.encode(handle.dealId, evaluatorConfig)
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);

        vm.recordLogs();
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 permitEvaluatorProposalId = _findDealProposalId(logs, AbstractDealManagementType.PERMIT_EVALUATOR_ADD);

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, permitEvaluatorProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, permitEvaluatorProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(permitEvaluatorProposalId);

        DealState memory state = IDealManagerAdapter(dealManager).state(handle.dealCell);
        assertEq(state.evaluators.length, 2);
        assertEq(RevenueBasedEvaluator(state.evaluators[1]).dealId(), handle.dealId);
        assertEq(RevenueBasedEvaluator(state.evaluators[1]).cell(), handle.dealCell);
        assertEq(state.evaluators[0], handle.evaluatorAddr);
        assertTrue(state.evaluators[1] != address(0));
    }

    function test_recoverProfits_emitsEventAndTransfersToTreasury() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();

        zeroFirstToken.mint(handle.dealAddr, 777);

        vm.expectEmit(true, false, false, true, handle.dealAddr);
        emit TreasuryDeal.ProfitsRecovered(address(zeroFirstToken), 777);

        vm.prank(agent1);
        TreasuryDeal(handle.dealAddr).recoverProfits(address(zeroFirstToken));

        assertEq(zeroFirstToken.balanceOf(handle.dealAddr), 0);
        assertEq(zeroFirstToken.balanceOf(treasuryAddr), 777);
    }

    function test_vetoEnabledHighQuorumProposal_waitsFullDuration() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        _enableDealVeto(handle);

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS,
                target: address(0),
                i: 0,
                data: abi.encode(true)
            })
        );
        vm.stopPrank();

        address proposal = Deal(handle.dealAddr).getProposal(proposalId);
        assertTrue(DealManagementProposal(proposal).vetoRight());

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);

        assertFalse(IVoting(proposal).isResolved());
        vm.expectRevert(DACErrorsLib.NotResolved.selector);
        IVoting(proposal).outcome();

        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(IVoting(proposal).isResolved());

        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
        assertTrue(IDealCell(handle.dealCell).allowEarlyReturns());
    }

    function test_vetoEnabledBlockingProposal_waitsFullDuration() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        _enableDealVeto(handle);

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(usdc),
                i: bytes32(uint256(2_000)),
                data: abi.encode(uint256(0))
            })
        );
        vm.stopPrank();

        address proposal = Deal(handle.dealAddr).getProposal(proposalId);
        assertTrue(DealManagementProposal(proposal).vetoRight());

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);

        assertFalse(IVoting(proposal).isResolved());
        vm.expectRevert(DACErrorsLib.NotResolved.selector);
        IVoting(proposal).outcome();

        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(IVoting(proposal).isResolved());

        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
        assertEq(IDealCell(handle.dealCell).fundingTranche(proposalId).amount, 2_000);
    }

    function test_dacCanVetoDealProposal_beforeExpiry() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        _enableDealVeto(handle);

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.REQUEST_TRANCHE,
                target: address(usdc),
                i: bytes32(uint256(2_500)),
                data: bytes("")
            })
        );
        vm.stopPrank();

        address proposal = Deal(handle.dealAddr).getProposal(proposalId);

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);

        assertFalse(IVoting(proposal).isResolved());

        vm.startPrank(founder);
        uint256 dacProposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAST_VETO_DEAL,
                target: address(0),
                i: 0,
                data: abi.encode(handle.dealId, proposalId)
            })
        );
        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(dacProposalId)).vote(true);
        dac.executeDACProposal(dacProposalId);
        vm.stopPrank();

        assertTrue(IVoting(proposal).isResolved());
        assertFalse(IVoting(proposal).outcome());
        assertTrue(DealManagementProposal(proposal).vetoCasted());

        vm.expectRevert(DACErrorsLib.VoteNotPassed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function test_createChildProposal_andVote_executesOnChildDAC() public {
        DealHandle memory handle = _setupApprovedDACDealWithTwoAgents();
        address childDac = DACDeal(handle.dealAddr).managedEntity();
        AgentToken childAgentToken = AgentToken(IDACCell(childDac).getAgentToken());

        ProposalParams memory childProposal = ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: agent2,
            i: bytes32(uint256(12_345)),
            data: bytes("")
        });

        (uint256 childProposalId, uint256 voteProposalId) = _createChildProposalViaParent(handle, childProposal);

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, voteProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, voteProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(voteProposalId);

        vm.prank(founder);
        IDACCell(childDac).executeDACProposal(childProposalId);

        assertEq(childAgentToken.balanceOf(agent2), 12_345);
    }

    function test_reinvestProfits_fulfillsChildCapitalCall() public {
        DealHandle memory handle = _setupApprovedDACDealWithTwoAgents();
        address childDac = DACDeal(handle.dealAddr).managedEntity();
        MainToken childMainToken = MainToken(IDACCell(childDac).getMainToken());

        bytes32 capitalCallHash = _createAndExecuteChildCapitalCall(handle, 22_222, 2_500);

        usdc.mint(handle.dealAddr, 2_500);

        uint256 childUsdcBefore = usdc.balanceOf(childDac);
        uint256 childMainBefore = childMainToken.balanceOf(handle.dealAddr);

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.REINVEST_PROFITS,
                target: address(usdc),
                i: 0,
                data: abi.encode(uint256(2_500), capitalCallHash)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertEq(usdc.balanceOf(childDac), childUsdcBefore + 2_500);
        assertEq(childMainToken.balanceOf(handle.dealAddr), childMainBefore + 22_222);
        assertEq(usdc.balanceOf(handle.dealAddr), 0);
    }

    function test_returnProfits_returnsTokensToParentDAC() public {
        DealHandle memory handle = _setupApprovedDACDealWithTwoAgents();

        usdc.mint(handle.dealAddr, 3_333);
        uint256 dacBalanceBefore = usdc.balanceOf(address(dac));

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_PROFITS,
                target: address(usdc),
                i: 0,
                data: abi.encode(uint256(3_333))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertEq(IDealCell(handle.dealCell).getReturnedCapital(address(usdc)), 3_333);
        assertEq(usdc.balanceOf(address(dac)), dacBalanceBefore + 3_333);
        assertEq(usdc.balanceOf(handle.dealAddr), 0);
    }

    function test_returnProfits_revertsForChildMainTokenBeforeClose() public {
        DealHandle memory handle = _setupApprovedDACDealWithTwoAgents();
        address childDac = DACDeal(handle.dealAddr).managedEntity();
        address childMainToken = IDACCell(childDac).getMainToken();

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.RETURN_PROFITS,
                target: childMainToken,
                i: 0,
                data: abi.encode(uint256(1))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);

        vm.expectRevert(DACErrorsLib.NotAllowed.selector);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);
    }

    function test_approvePermit2Spend_supportsZeroFirstTokensAcrossRepeatedApprovals() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address spender1 = makeAddr("spender-1");
        address spender2 = makeAddr("spender-2");

        zeroFirstToken.mint(treasuryAddr, 10_000);

        vm.startPrank(agent1);
        uint256 proposalId1 = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(zeroFirstToken),
                i: 0,
                data: abi.encode(spender1, uint160(2_000), uint48(block.timestamp + 1 days))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId1, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId1, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId1);

        vm.startPrank(agent1);
        uint256 proposalId2 = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(zeroFirstToken),
                i: 0,
                data: abi.encode(spender2, uint160(3_000), uint48(block.timestamp + 2 days))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId2, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId2, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId2);

        assertEq(zeroFirstToken.allowance(treasuryAddr, permit2), type(uint160).max);
    }

    function test_approveDirectSpend_transfersTreasuryFunds() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address recipient = makeAddr("recipient");
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_DIRECT_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(recipient, uint160(3_000))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertEq(usdc.balanceOf(recipient), 3_000);
        assertEq(usdc.balanceOf(treasuryAddr), 7_000);
    }

    function test_approvePermit2Spend_callsPermit2AndSetsAllowance() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address spender = makeAddr("permit2-spender");
        uint160 amount = 2_750;
        uint48 expiration = uint48(block.timestamp + 7 days);

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_PERMIT2_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(spender, amount, expiration)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);

        vm.expectCall(
            permit2,
            abi.encodeWithSelector(
                IPermit2.approve.selector,
                address(usdc),
                spender,
                amount,
                expiration
            )
        );
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertEq(usdc.allowance(treasuryAddr, permit2), uint256(type(uint160).max));
    }

    function test_approveAgentSpend_allowsAgentToExecuteSpend() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address destination = makeAddr("destination");

        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: 4_000,
            singleTxAmount: 2_500,
            clockLimit: 0,
            duration: 1 days
        });

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(agent1, destination, allowance)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        Permit2Treasury treasury = Permit2Treasury(treasuryAddr);
        bytes32 allowanceHash = keccak256(abi.encode(agent1, address(usdc), destination));
        (uint160 totalAmount, uint160 singleTxAmount,,) = treasury.agentAllowance(allowanceHash);
        assertEq(totalAmount, 4_000);
        assertEq(singleTxAmount, 2_500);

        vm.prank(agent1);
        treasury.executeAgentSpend(address(usdc), destination, 1_500);

        assertEq(usdc.balanceOf(destination), 1_500);
        assertEq(usdc.balanceOf(treasuryAddr), 8_500);
        (uint160 remainingAmount,,,) = treasury.agentAllowance(allowanceHash);
        assertEq(remainingAmount, 2_500);
    }

    function test_assignClaimer_and_revokeAgent_updateTreasuryPermissions() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        address counterparty = makeAddr("counterparty");

        TreasurySpendAllowance memory allowance = TreasurySpendAllowance({
            totalAmount: 4_000,
            singleTxAmount: 2_000,
            clockLimit: 0,
            duration: 1 days
        });

        vm.startPrank(agent1);
        uint256 assignProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.ASSIGN_CLAIMER,
                target: agent1,
                i: 0,
                data: abi.encode(address(usdc), counterparty, uint160(2_500))
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, assignProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, assignProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(assignProposalId);

        vm.startPrank(agent1);
        uint256 spendProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.APPROVE_AGENT_SPEND,
                target: address(usdc),
                i: 0,
                data: abi.encode(agent1, counterparty, allowance)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, spendProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, spendProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(spendProposalId);

        Permit2Treasury treasury = Permit2Treasury(treasuryAddr);
        bytes32 accessHash = keccak256(abi.encode(agent1, address(usdc), counterparty));
        assertEq(treasury.approvedAgents(accessHash), 2_500);
        (uint160 totalAmount,,,) = treasury.agentAllowance(accessHash);
        assertEq(totalAmount, 4_000);

        vm.startPrank(agent1);
        uint256 revokeProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.REVOKE_AGENT,
                target: address(usdc),
                i: 0,
                data: abi.encode(agent1, counterparty)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, revokeProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, revokeProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(revokeProposalId);

        assertEq(treasury.approvedAgents(accessHash), 0);
        (uint160 remainingAmount,,,) = treasury.agentAllowance(accessHash);
        assertEq(remainingAmount, 0);
    }

    function test_delegateVoteRights_delegatesTreasuryHeldVotes() public {
        DealHandle memory handle = _setupApprovedTreasuryDealWithTwoAgents();
        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        uint256 treasuryVotes = 50_000e18;

        govToken.mint(founder, treasuryVotes);
        vm.startPrank(founder);
        govToken.delegate(founder);
        govToken.transfer(treasuryAddr, treasuryVotes);
        vm.stopPrank();

        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.DELEGATE_VOTE_RIGHTS,
                target: address(0),
                i: 0,
                data: abi.encode(address(govToken), agent2)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertEq(govToken.delegates(treasuryAddr), agent2);
        assertEq(govToken.getVotes(agent2), treasuryVotes);
    }

    function _setupApprovedTreasuryDealWithTwoAgents() internal returns (DealHandle memory handle) {
        handle = createTreasuryDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);
    }

    function _setupApprovedDACDealWithTwoAgents() internal returns (DealHandle memory handle) {
        handle = createDACDeal(agent1);

        vm.warp(block.timestamp + 1);
        _stakeAndDelegate(agent1, handle.dealCell, 20_000);
        vm.prank(agent1);
        IDealCell(handle.dealCell).invite(agent2, true);
        _stakeAndDelegate(agent2, handle.dealCell, 20_000);
        _approveDeal(handle);
        vm.warp(block.timestamp + 1);
    }

    function _enableDealVeto(DealHandle memory handle) internal {
        vm.startPrank(agent1);
        uint256 proposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: AbstractDealManagementType.ENABLE_VETO_RIGHT,
                target: address(0),
                i: 0,
                data: bytes("")
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, proposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, proposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(proposalId);

        assertTrue(IDealCell(handle.dealCell).allowDACVeto());
        vm.warp(block.timestamp + 1);
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

    function _voteDealProposal(address dealAddr, uint256 proposalId, address voter, bool support) internal {
        address proposal = Deal(dealAddr).getProposal(proposalId);
        vm.prank(voter);
        IVoting(proposal).vote(support);
    }

    function _createTreasuryDealWithLogs(address agent)
        internal
        returns (DealHandle memory handle, Vm.Log[] memory logs)
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
            extension: 0
        });
        milestones[0].rewardCurve[0] = 1e18;
        milestones[0].penaltyCurve[0] = 1e18;

        MilestoneBasedEvaluator.Config memory evaluatorCfg =
            MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones);

        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) = IDealManager(dealManager)
            .createDealProposal(
                DealParams({
                    dealKind: CoreDealType.PERMIT2_TREASURY,
                    name: "Test Treasury Deal",
                    description: "Test Treasury Deal description",
                    linkHash: "0x00112233",
                    moduleFactory: address(coreModule),
                    governanceFactory: address(coreDealGovernanceFactory),
                    dealTarget: address(0),
                    proposer: agent,
                    vetoEnabled: false,
                    fundingToken: address(usdc),
                    fundingAmount: 10_000,
                    rewardsLimit: 500e6,
                    approveDeadline: block.timestamp + 1 days,
                    evaluationDeadline: block.timestamp + 15 days,
                    dealDeadline: block.timestamp + 30 days,
                    evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
                    dealConfig: abi.encode("deal config"),
                    evaluatorConfig: abi.encode(evaluatorCfg)
                })
            );

        vm.stopPrank();

        logs = vm.getRecordedLogs();

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
                break;
            }
        }
    }

    function _findProposalIdFromData(Vm.Log[] memory logs, bytes32 eventSig) internal pure returns (uint256 proposalId) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return uint256(logs[i].topics[3]);
            }
        }

        revert("proposal id not found");
    }

    function _findDealProposalId(Vm.Log[] memory logs, bytes4 proposalType) internal pure returns (uint256 proposalId) {
        bytes32 eventSig = keccak256("DealManagementProposalCreated(address,address,uint256,bytes4,address,bytes32,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig && logs[i].topics[3] == bytes32(proposalType)) {
                (proposalId,,,) = abi.decode(logs[i].data, (uint256, address, bytes32, bytes));
                return proposalId;
            }
        }

        revert("deal proposal id not found");
    }

    function _findRelatedContract(Vm.Log[] memory logs)
        internal
        pure
        returns (
            uint256 loggedId,
            address relatedContract,
            address loggedDeal,
            address loggedDealCell,
            bytes32 role,
            bool controlled,
            bool managed
        )
    {
        bytes32 eventSig = keccak256("DealRelatedContract(address,uint256,address,address,address,bytes32,bool,bool)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                loggedId = uint256(logs[i].topics[2]);
                relatedContract = address(uint160(uint256(logs[i].topics[3])));
                (loggedDeal, loggedDealCell, role, controlled, managed) =
                    abi.decode(logs[i].data, (address, address, bytes32, bool, bool));
                return (loggedId, relatedContract, loggedDeal, loggedDealCell, role, controlled, managed);
            }
        }

        revert("related contract event not found");
    }

    function _createChildProposalViaParent(
        DealHandle memory handle,
        ProposalParams memory childProposal
    ) internal returns (uint256 childProposalId, uint256 voteProposalId) {
        vm.startPrank(agent1);
        uint256 createProposalId = Deal(handle.dealAddr).createStakedAgentProposal(
            ProposalParams({
                typ: CoreDealManagementType.CREATE_DAC_PROPOSAL,
                target: address(0),
                i: 0,
                data: abi.encode(childProposal)
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, createProposalId, agent1, true);

        vm.recordLogs();
        Deal(handle.dealAddr).executeStakedAgentProposal(createProposalId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        return _findChildVoteCreated(logs);
    }

    function _createAndExecuteChildCapitalCall(
        DealHandle memory handle,
        uint256 tokenAmount,
        uint256 cashAmount
    ) internal returns (bytes32 callHash) {
        ProposalParams memory childProposal = ProposalParams({
            typ: DACManagementProposalType.CAPITAL_CALL,
            target: handle.dealAddr,
            i: bytes32(tokenAmount),
            data: abi.encode(address(usdc), cashAmount)
        });

        (uint256 childProposalId, uint256 voteProposalId) = _createChildProposalViaParent(handle, childProposal);

        vm.warp(block.timestamp + 1);
        _voteDealProposal(handle.dealAddr, voteProposalId, agent1, true);
        _voteDealProposal(handle.dealAddr, voteProposalId, agent2, true);
        Deal(handle.dealAddr).executeStakedAgentProposal(voteProposalId);

        vm.recordLogs();
        vm.prank(founder);
        IDACCell(DACDeal(handle.dealAddr).managedEntity()).executeDACProposal(childProposalId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        callHash = _findCapitalCallHash(logs);
        vm.warp(block.timestamp + 1);
    }

    function _findChildVoteCreated(Vm.Log[] memory logs) internal pure returns (uint256 childProposalId, uint256 voteProposalId) {
        bytes32 eventSig = keccak256("ChildVoteCreated(uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                childProposalId = uint256(logs[i].topics[1]);
                voteProposalId = abi.decode(logs[i].data, (uint256));
                return (childProposalId, voteProposalId);
            }
        }

        revert("child vote event not found");
    }

    function _findCapitalCallHash(Vm.Log[] memory logs) internal pure returns (bytes32 callHash) {
        bytes32 eventSig =
            keccak256("CapitalCallCreated(uint256,address,bytes32,address,uint256,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                return logs[i].topics[3];
            }
        }

        revert("capital call hash not found");
    }
}
