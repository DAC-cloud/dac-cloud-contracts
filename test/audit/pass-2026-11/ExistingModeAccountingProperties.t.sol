// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Existing-token mode end to end: reward reserve, funding
// conservation, capital return. test_VERIFY_* checks a property end to end.

import "forge-std/Test.sol";
import {DACTestBase, MockUSDC} from "../../base/DACTestBase.t.sol";
import {DealParams, ProposalParams, EvaluationResult, ExistingDACConfig} from "../../../src/interfaces/Structs.sol";
import {GovernanceStrategyConfig} from "../../../src/interfaces/GovernanceStructs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {DACErrorsLib} from "../../../src/interfaces/DACErrorsLib.sol";
import {DACCell} from "../../../src/kernel/DACCell.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {AgentToken} from "../../../src/kernel/tokens/AgentToken.sol";
import {WrappedMainToken} from "../../../src/kernel/tokens/WrappedMainToken.sol";
import {ExistingTokenAssetController} from "../../../src/kernel/controllers/ExistingTokenAssetController.sol";
import {DACManagementProposalType} from "../../../src/kernel/governance/DACManagementProposals.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {CoreDealType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {TreasuryDeal} from "../../../src/modules/core/deals/TreasuryDeal.sol";
import {TreasuryDealFactory} from "../../../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {
    MockEvaluator,
    MockEvaluatorFactory,
    MockEvaluatorModuleFactory,
    MOCK_EVALUATOR_SELECTOR
} from "../../DealEvaluationRecoveryTest.t.sol";

/// Existing-token DAC, end to end through the real factory and hybrid governance:
/// reserve-backed reward commitments, funding-token conservation, clawback.
contract ExistingModeAccountingProperties is DACTestBase {
    address holder = makeAddr("existing-holder");
    address agentX = makeAddr("agent-x");
    address outsider = makeAddr("outsider");

    DACCell xdac;
    WrappedMainToken wrapped;
    AgentToken xAgent;
    ExistingTokenAssetController ctl;
    address xManager;
    MockUSDC underlying;
    MockEvaluatorModuleFactory mockModule;

    function setUp() public {
        setUpBase();
        underlying = new MockUSDC();
        underlying.mint(holder, 10_000e18);

        vm.startPrank(moduleOwner);
        mockModule = new MockEvaluatorModuleFactory(
            address(new TreasuryDealFactory(permit2)), address(new MockEvaluatorFactory())
        );
        vm.stopPrank();

        ExistingDACConfig memory cfg = ExistingDACConfig({
            symbol: "EX",
            name: "Existing",
            description: "x",
            underlyingToken: address(underlying),
            treasurySeedAmount: 1_000e18,
            governanceOracle: address(0),
            dividendsEnabled: false,
            governanceStrategy: GovernanceStrategyConfig({
                quorumPercent: MathLib.atScale(50),
                highQuorumPercent: MathLib.atScale(75),
                blockingPercent: MathLib.atScale(20),
                duration: 7 days,
                qualification: 0,
                executionValidityDuration: 1 days,
                oraclePublishDeadline: 0,
                fallbackWarmupDuration: 1 hours,
                fallbackDuration: 3 days,
                blockingOnAllProposals: false,
                blockingOnHighQuorum: false,
                oraclePrimaryEnabled: false,
                voteRetentionPercent: 0,
                voteLockDuration: 0
            })
        });

        vm.startPrank(holder);
        underlying.approve(address(dacFactory), 1_000e18);
        (address d, address w, address a) = dacFactory.deployExistingTokenDAC(abi.encode(cfg), bytes32("ex"));
        underlying.approve(w, type(uint256).max);
        WrappedMainToken(w).wrap(5_000e18);
        vm.stopPrank();
        // Proposal qualification reads votes at the previous second.
        vm.warp(block.timestamp + 1);

        xdac = DACCell(d);
        wrapped = WrappedMainToken(w);
        xAgent = AgentToken(a);
        ctl = ExistingTokenAssetController(xdac.getAssetController());
        xManager = xdac.getDealManager();

        _passHybrid(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
            })
        );
        _passHybrid(
            ProposalParams({
                typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                target: agentX,
                i: bytes32(uint256(100_000)),
                data: bytes("")
            })
        );
    }

    function test_VERIFY_existingMode_rewardReserve_fundingConservation_clawback() public {
        // Treasury gets its funding token through the permissionless sweep.
        usdc.mint(address(xdac), 10_000);
        vm.prank(outsider);
        xdac.recoverERC20(address(usdc));
        assertEq(ctl.treasuryBalance(address(usdc)), 10_000);
        assertEq(ctl.treasuryBalance(address(wrapped)), 1_000e18);

        // Deal: 10,000 USDC funding, 300 wrapped reward limit.
        DealParams memory p = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "X",
            description: "",
            linkHash: "",
            moduleFactory: address(mockModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agentX,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 300e18,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: MOCK_EVALUATOR_SELECTOR,
            dealConfig: abi.encode("x"),
            evaluatorConfig: abi.encode(address(this), new EvaluationResult[](0)),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
        vm.recordLogs();
        vm.prank(agentX);
        (uint256 dealId, address dealCell, address dealAddr, address evaluator) =
            IDealManager(xManager).createDealProposal(p);
        uint256 pid = _dealCreatedProposalId(vm.getRecordedLogs());
        vm.prank(agentX);
        xAgent.stakeToDeal(dealCell, 20_000);

        _voteExecHybrid(pid);

        address dealTreasury = TreasuryDeal(dealAddr).managedEntity();
        // Funding token conserved hop by hop; nothing left in transit contracts.
        assertEq(usdc.balanceOf(dealTreasury), 10_000);
        assertEq(
            usdc.balanceOf(address(ctl)) + usdc.balanceOf(xManager) + usdc.balanceOf(dealCell)
                + usdc.balanceOf(dealAddr),
            0
        );
        assertEq(ctl.treasuryBalance(address(usdc)), 0);
        // Reward limit is reserved out of the wrapped reserve, not minted.
        assertEq(ctl.committedBalance(address(wrapped)), 300e18);
        assertEq(ctl.mainTokenObligations(), 300e18);
        assertEq(ctl.freeBalance(address(wrapped)), 700e18);
        _assertVotable();

        // A capital call cannot dip into the committed reserve.
        vm.prank(holder);
        uint256 ccPid = xdac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.CAPITAL_CALL,
                target: holder,
                i: bytes32(uint256(701e18)),
                data: abi.encode(address(usdc), uint256(1), block.timestamp + 30 days)
            })
        );
        vm.warp(block.timestamp + 1 hours + 1);
        address ccProp = xdac.getProposalVoting(ccPid);
        vm.prank(holder);
        IVoting(ccProp).vote(true);
        vm.expectRevert(DACErrorsLib.InsufficientTreasury.selector);
        xdac.executeDACProposal(ccPid);

        // Convert 50%: agent claims 150 wrapped from the reserve.
        MockEvaluator(evaluator).setResults(_single(1, MathLib.atScale(50)));
        vm.prank(agentX);
        DealManager(xManager).evaluateDeal(dealId, 0);
        uint256 supplyBefore = wrapped.totalSupply();
        vm.prank(agentX);
        IDealCell(dealCell).claimMainToken(0);
        assertEq(wrapped.balanceOf(agentX), 150e18);
        assertEq(wrapped.totalSupply(), supplyBefore, "paid from reserve, no mint");
        assertEq(ctl.committedBalance(address(wrapped)), 150e18);
        assertEq(ctl.mainTokenObligations(), 150e18);
        assertEq(ctl.treasuryBalance(address(wrapped)), 850e18);
        assertEq(wrapped.balanceOf(address(ctl)), 850e18);
        assertEq(ctl.freeBalance(address(wrapped)), 700e18);
        _assertVotable();

        // A donation plus sync only ever raises the free balance.
        vm.prank(holder);
        wrapped.transfer(address(ctl), 10e18);
        vm.prank(holder);
        xdac.recoverTreasury(address(wrapped));
        assertEq(ctl.treasuryBalance(address(wrapped)), 860e18);
        assertEq(ctl.committedBalance(address(wrapped)), 150e18);
        _assertVotable();

        // Close: the unused half of the reservation is released, exactly once.
        MockEvaluator(evaluator).setResults(_single(3, 0));
        vm.prank(agentX);
        DealManager(xManager).evaluateDeal(dealId, 0);
        assertTrue(IDealCell(dealCell).isClosed());
        assertEq(ctl.committedBalance(address(wrapped)), 0);
        assertEq(ctl.mainTokenObligations(), 0);
        assertEq(ctl.freeBalance(address(wrapped)), 860e18);

        // Agent exits; the DAC claws the funding token back before the deadline.
        vm.prank(agentX);
        IDealCell(dealCell).unstake();
        assertEq(xAgent.balanceOf(agentX), 100_000);
        vm.prank(holder);
        DealManager(xManager).forceReturnCapital(dealId);
        assertEq(usdc.balanceOf(address(ctl)), 10_000);
        assertEq(ctl.treasuryBalance(address(usdc)), 10_000);
        assertEq(
            usdc.balanceOf(dealTreasury) + usdc.balanceOf(xManager) + usdc.balanceOf(dealCell)
                + usdc.balanceOf(dealAddr),
            0
        );
        assertEq(IDealCell(dealCell).getReturnedCapital(address(usdc)), 10_000);

        // 1:1 backing of the wrapper holds throughout.
        assertEq(underlying.balanceOf(address(wrapped)), wrapped.totalSupply());
        _assertVotable();
    }

    function _assertVotable() internal view {
        // Only the controller holds wrapped among controlled addresses in this scenario.
        assertEq(ctl.totalReleasedVotable(), wrapped.totalSupply() - wrapped.balanceOf(address(ctl)));
    }

    function _passHybrid(ProposalParams memory p) internal returns (uint256 pid) {
        vm.prank(holder);
        pid = xdac.createManagementProposal(p);
        _voteExecHybrid(pid);
    }

    function _voteExecHybrid(uint256 pid) internal {
        vm.warp(block.timestamp + 1 hours + 1);
        address prop = xdac.getProposalVoting(pid);
        vm.prank(holder);
        IVoting(prop).vote(true);
        xdac.executeDACProposal(pid);
    }

    function _dealCreatedProposalId(Vm.Log[] memory logs) internal pure returns (uint256 pid) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                pid = uint256(logs[i].topics[3]);
            }
        }
        require(pid != 0, "no deal proposal");
    }

    function _single(uint8 action, uint256 percent) internal pure returns (EvaluationResult[] memory r) {
        r = new EvaluationResult[](1);
        r[0] = EvaluationResult(action, percent, 0);
    }
}
