// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md). Evaluators measure a deal from its activation (M-04).
//   test_REG_*     a scenario closed in the hardening round: the test replays it and asserts
//                  that it no longer works.
//   test_CONTROL_* the baseline a scenario is measured against.

import "forge-std/Test.sol";
import {DACTestBase} from "../../base/DACTestBase.t.sol";
import {DealParams} from "../../../src/interfaces/Structs.sol";
import {IVoting} from "../../../src/interfaces/IVoting.sol";
import {IDealCell} from "../../../src/interfaces/IDealCell.sol";
import {IDealManager} from "../../../src/interfaces/IDealManager.sol";
import {StakedAgent} from "../../../src/kernel/tokens/StakedAgent.sol";
import {DealManager} from "../../../src/kernel/DealManager.sol";
import {CoreDealType, CoreEvaluatorType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {MilestoneBasedEvaluator} from "../../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {RevenueBasedEvaluator} from "../../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {Milestone, RevenueSchedule} from "../../../src/modules/core/interfaces/Structs.sol";
import {IPriceOracle} from "../../../src/modules/core/interfaces/IPriceOracle.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";

contract ActivationPermit2Stub {
    function approve(address, address, uint160, uint48) external pure {}
}

contract ActivationPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function tokenPrice(address token) external view returns (uint256) {
        return prices[token];
    }
}

/// M-04. A deal is proposed, voted on for days, and only then approved. Its evaluators
/// count cycles and take reference prices from the approval, not from the proposal.
contract EvaluatorActivation is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    ActivationPriceOracle internal priceOracle;
    address internal constant PRICED_TOKEN = address(0xBEEF);

    function setUp() public {
        setUpBase();
        vm.etch(permit2, address(new ActivationPermit2Stub()).code);
        onboardAgent(agent1);
        onboardAgent(agent2);
        priceOracle = new ActivationPriceOracle();
    }

    /*//////////////////////////////////////////////////////////////
                        revenue schedule
    //////////////////////////////////////////////////////////////*/

    function _schedule(uint256 evaluationStart) internal view returns (RevenueSchedule memory schedule) {
        schedule = RevenueSchedule({
            token: address(usdc),
            duration: 1 days,
            revenueProjectionMode: 0,
            revenueProjection: 1_000e6,
            curveCoeffs: new int256[](2),
            requirementCurveCoeffs: new int256[](1),
            maxCycleUnlockPercent: 5e16,
            minCycleRevenuePercent: 5e17,
            graceCycles: 1,
            penaltyPerMiss: 1e17,
            evaluationStart: evaluationStart,
            autoClose: false,
            excludePrincipal: true
        });
        schedule.curveCoeffs[0] = 0;
        schedule.curveCoeffs[1] = 1e18;
        schedule.requirementCurveCoeffs[0] = 1e18;
    }

    function _revenueDeal(uint256 evaluationStart) internal returns (DealHandle memory handle) {
        handle = _createTreasuryDealWith(
            agent1,
            CoreEvaluatorType.REVENUE_EVALUATOR,
            abi.encode(RevenueBasedEvaluator.Config(MathLib.atScale(100), _schedule(evaluationStart)))
        );
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
    }

    function _approveAfter(DealHandle memory handle, uint256 delay) internal returns (uint256 approvedAt) {
        vm.warp(block.timestamp + delay);
        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();
        assertTrue(IDealCell(handle.dealCell).isApproved());
        approvedAt = IDealCell(handle.dealCell).approvedAt();
        assertEq(approvedAt, block.timestamp);
    }

    // The DAC takes five days to approve. No cycle is counted for those five days.
    function test_REG_M04_revenueSchedule_countsFromApproval() public {
        DealHandle memory handle = _revenueDeal(0);
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        uint256 approvedAt = _approveAfter(handle, 5 days + 10);

        // Evaluated in the block of its approval: the deal has been live for zero seconds.
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(stake.balanceOf(agent1), 20_000, "nothing slashed");
        assertEq(evaluator.totalEvaluatedCycles(), 0, "no cycle has run yet");
        assertEq(evaluator.lastChecked(), approvedAt, "the schedule starts at the approval");

        // The first cycle ends one period after the approval.
        vm.warp(approvedAt + 1 days - 1);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 0);

        vm.warp(approvedAt + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 1);
        assertEq(stake.balanceOf(agent1), 20_000, "first miss is within the grace cycle");
    }

    // An explicit start that falls before the approval is moved up to it as well.
    function test_REG_M04_explicitStartBeforeApproval_movesToApproval() public {
        DealHandle memory handle = _revenueDeal(block.timestamp + 1 days);
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        uint256 approvedAt = _approveAfter(handle, 5 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(evaluator.lastChecked(), approvedAt);
        assertEq(evaluator.totalEvaluatedCycles(), 0);
    }

    // Control: a start set after the approval is the proposer's choice and is kept.
    function test_CONTROL_M04_explicitStartAfterApproval_isKept() public {
        uint256 start = block.timestamp + 10 days;
        DealHandle memory handle = _revenueDeal(start);
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(handle.evaluatorAddr);

        _approveAfter(handle, 5 days);

        vm.warp(start + 1 days - 1);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.lastChecked(), start);
        assertEq(evaluator.totalEvaluatedCycles(), 0);

        vm.warp(start + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.totalEvaluatedCycles(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    growth milestone: reference price
    //////////////////////////////////////////////////////////////*/

    // One milestone: the priced token must be worth 1.5x its reference price by the
    // milestone date. Reached pays everything; missed pays nothing and slashes everything.
    function _growthDeal() internal returns (DealHandle memory handle) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: PRICED_TOKEN,
            oracle: address(priceOracle),
            valuationMode: 2,
            fundingToken: address(0),
            expectedReturn: 15e17,
            timestamp: block.timestamp + 10 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0,
            excludePrincipal: false
        });
        milestones[0].rewardCurve[0] = 0;
        milestones[0].penaltyCurve[0] = 1e18;

        handle = _createTreasuryDealWith(
            agent1,
            CoreEvaluatorType.MILESTONES_EVALUATOR,
            abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones))
        );
        vm.warp(block.timestamp + 1);
        vm.prank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
    }

    // The price doubles while the DAC is still voting. That move happened before the deal
    // existed and earns nothing: growth is measured from the price at approval.
    function test_REG_M04_growthBaseline_isThePriceAtApproval() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        MilestoneBasedEvaluator evaluator = MilestoneBasedEvaluator(handle.evaluatorAddr);
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 0, "no reference price before the deal is live");

        priceOracle.setPrice(PRICED_TOKEN, 2e18);
        _approveAfter(handle, 5 days);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 2e18, "reference price taken at approval");

        // The price stays where it was at approval: growth is 1.0x, not the 2.0x since proposal.
        vm.warp(block.timestamp + 6 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), 0, "milestone not reached");
        assertEq(stake.balanceOf(agent1), 0, "and its penalty applied");
    }

    // Control: the same move after the approval is the agents' result and is paid.
    function test_CONTROL_M04_growthAfterApproval_reachesTheMilestone() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        StakedAgent stake = StakedAgent(IDealCell(handle.dealCell).stakeToken());

        priceOracle.setPrice(PRICED_TOKEN, 2e18);
        _approveAfter(handle, 5 days);

        priceOracle.setPrice(PRICED_TOKEN, 3e18); // 1.5x the price at approval
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);

        assertEq(IDealCell(handle.dealCell).rewardsConvertedPct(), MathLib.SCALE);
        assertEq(stake.balanceOf(agent1), 20_000);
    }

    // A reference price the oracle cannot give at approval is taken at the first evaluation
    // instead; the approval itself is never held up by an evaluator.
    function test_REG_M04_oracleSilentAtApproval_doesNotBlockIt() public {
        priceOracle.setPrice(PRICED_TOKEN, 1e18);
        DealHandle memory handle = _growthDeal();
        MilestoneBasedEvaluator evaluator = MilestoneBasedEvaluator(handle.evaluatorAddr);

        priceOracle.setPrice(PRICED_TOKEN, 0);
        _approveAfter(handle, 5 days);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 0);

        priceOracle.setPrice(PRICED_TOKEN, 4e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent1);
        DealManager(dealManager).evaluateDeal(handle.dealId, 0);
        assertEq(evaluator.snapshotPrice(PRICED_TOKEN), 4e18);
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _createTreasuryDealWith(address agent, bytes4 evaluatorSelector, bytes memory evaluatorConfig)
        internal
        returns (DealHandle memory handle)
    {
        vm.recordLogs();

        DealParams memory params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Treasury Deal",
            description: "evaluator activation",
            linkHash: "0x00",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 1_000e6,
            rewardsLimit: 1_000e18,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 7 days,
            evaluationDeadline: block.timestamp + 30 days,
            dealDeadline: block.timestamp + 60 days,
            dealConfig: abi.encode("deal config"),
            evaluatorSelector: evaluatorSelector,
            evaluatorConfig: evaluatorConfig,
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        vm.prank(agent);
        (uint256 dealId, address dealCell, address dealAddr, address evaluatorAddr) =
            IDealManager(dealManager).createDealProposal(params);

        handle.dealId = dealId;
        handle.dealCell = dealCell;
        handle.dealAddr = dealAddr;
        handle.evaluatorAddr = evaluatorAddr;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DealCreated(address,uint256,uint256,address,bytes4,address,address)")) {
                handle.proposalId = uint256(logs[i].topics[3]);
            }
        }
    }
}
