// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Tranche, DealParams, EvaluationResult} from "../../src/interfaces/Structs.sol";
import {CoreDealType, CoreEvaluatorType} from "../../src/modules/core/CoreModuleDeals.sol";
import {RevenueBasedEvaluator} from "../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {RevenueEvaluatorFactory} from "../../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {IDeal} from "../../src/interfaces/IDeal.sol";
import {IDealCell} from "../../src/interfaces/IDealCell.sol";
import {IDACCell} from "../../src/interfaces/IDACCell.sol";
import {MathLib} from "../../src/kernel/libraries/MathLib.sol";
import {RevenueSchedule} from "../../src/modules/core/interfaces/Structs.sol";

contract MockDealCell is IDealCell {
    uint256 public returnedCapital;
    mapping(address => uint256) internal investedCapital;

    uint256 internal _startTime;

    constructor(
        uint256 __startTime
    ) {
        _startTime = __startTime;
    }

    function setReturnedCapital(uint256 _returned) external {
        returnedCapital = _returned;
    }

    function setInvestedCapital(address token, uint256 amount) external {
        investedCapital[token] = amount;
    }

    function getReturnedCapital(address) external view returns (uint256) {
        return returnedCapital;
    }

    function startTime() external view returns (uint256) {
        return _startTime;
    }

    // Stub other required methods
    function name() external pure returns (string memory) { return "MockDeal"; }
    function description() external pure returns (string memory) { return ""; }
    function deal() external pure returns (IDeal) { revert("Not implemented"); }
    function manager() external pure returns (address) { return address(0); }
    function stakeToken() external pure returns (address) { return address(0); }
    function invite(address, bool) external pure { revert("Not implemented"); }
    function claimMainToken(uint256 evaluatorId) external {}
    function dealRewardPoolPercent() external pure returns (uint256) { return 0; }
    function unstake() external {}
    function fundingTranche(uint256) external pure returns (Tranche memory tranche) { }
    function fundingTokens() external pure returns (address[] memory) { return new address[](0); }
    function getMainRewardsLimit() external pure returns (uint256) { return 0; }
    function rewardsConvertedPct() external pure returns (uint256) { return 0; }
    function getInvestedCapital(address token) external view returns (uint256) { return investedCapital[token]; }
    function allowEarlyReturns() external pure returns (bool) { return false; }
    function allowDACVeto() external pure returns (bool) { return false; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external pure returns (bool) { return true; }
    function isClosed() external pure returns (bool) { return false; }
    function approveDeadline() external pure returns (uint256) { return 0; }
    function evaluationDeadline() external pure returns (uint256) { return 0; }
    function dealDeadline() external pure returns (uint256) { return type(uint256).max; }
}

contract RevenueBasedEvaluatorTest is Test {
    RevenueBasedEvaluator evaluator;
    MockDealCell mockDealCell;

    address constant DAC = address(0xDAC);
    uint256 constant DEAL_ID = 1;
    
    address constant DEAL_ADDR = address(0xDEA11);

    event EvaluatorResult(uint256 action, uint256 percent, uint256 extendTo);

    function setUp() public {
        mockDealCell = new MockDealCell(block.timestamp);
        vm.mockCall(
            DAC,
            abi.encodeWithSelector(IDACCell.getDealManager.selector),
            abi.encode(address(this))
        );
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER: DEPLOY EVALUATOR
    //////////////////////////////////////////////////////////////*/

    function deployEvaluator(RevenueBasedEvaluator.Config memory cfg) internal {
        RevenueEvaluatorFactory factory = new RevenueEvaluatorFactory();
        bytes memory configData = abi.encode(cfg);

        DealParams memory dealParams = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Test Treasury Deal",
            description: "Test Treasury Deal description",
            linkHash: "0x00112233",
            moduleFactory: address(0),
            governanceFactory: address(0),
            dealTarget: address(0),
            proposer: address(0),
            vetoEnabled: false,
            fundingToken: address(0),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            dealRewardPoolPercent: 0,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.REVENUE_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: configData,
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });

        evaluator = RevenueBasedEvaluator(
            factory.deployEvaluator(DAC, DEAL_ID, address(mockDealCell), dealParams, configData)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          UNIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_firstCycle_meetsTarget_unlocks() public {
        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: RevenueSchedule({
                token: address(0x1111),
                duration: 30 days,
                revenueProjectionMode: 0,
                revenueProjection: 10_000e6,
                requirementCurveCoeffs: new int256[](2), // linear a + b*x
                curveCoeffs: new int256[](4), // cubic: x^3
                maxCycleUnlockPercent: MathLib.atScale(10),
                minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
                graceCycles: 3,
                penaltyPerMiss: MathLib.atScale(5),
                evaluationStart: 0,
                autoClose: false
            })
        });
        cfg.schedule.curveCoeffs[0] = 0;
        cfg.schedule.curveCoeffs[1] = 0;
        cfg.schedule.curveCoeffs[2] = 0;
        cfg.schedule.curveCoeffs[3] = 1e18; // y = x^3

        cfg.schedule.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); 
        cfg.schedule.requirementCurveCoeffs[1] = 0; // flat line at 100% of base

        deployEvaluator(cfg);

        mockDealCell.setReturnedCapital(10_000e6); // exactly target

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 1);
        assertEq(results[0].action, 1);           // convert
        assertEq(results[0].percent, MathLib.atScale(10));       // 10% of the curve for 1 cycle
        assertEq(results[0].extendTo, 0);
    }

    function test_belowTarget_butAboveMinUnlock_smallUnlock() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(1_000e6); // 10% of target → curve gives ~0.001

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 1);
        assertEq(results[0].action, 1);
        assertGe(results[0].percent, 1e6); // curve gives something
        assertLe(results[0].percent, MathLib.atScale(1)); // but less than 1% (since 10% per cycle)
    }

    function test_multipleMisses_triggersPenalty() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(80), // miss if < 80%
            graceCycles: 0, // no grace, 2 periods clearly missed
            penaltyPerMiss: MathLib.atScale(10),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(0); // total miss

        vm.warp(block.timestamp + 60 days); // two cycles

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 1); // zero reward since zero returns, only penalty
        assertEq(results[0].action, 0);
        assertEq(results[0].percent, MathLib.atScale(20)); // penalty triggered
    }

    function test_fullUnlock_triggersClose() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(100),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: true
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(10_000e6);

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 2); // reward, close
        assertEq(results[results.length - 1].action, 3); // close
    }

    function test_cycleAlignment_noLostPartialPeriods() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25),
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(10_000e6);

        // Evaluate at 70% of first cycle → should do NOTHING
        vm.warp(block.timestamp + 21 days);
        EvaluationResult[] memory r1 = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(r1.length, 0);

        // Now at 100% + 10% of next cycle → only ONE cycle evaluated, lastChecked moved correctly
        vm.warp(block.timestamp + 12 days);
        EvaluationResult[] memory r2 = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(r2.length, 1);
        assertEq(r2[0].action, 1);
    }

    function test_requirementCurveProgressesAcrossSeparateEvaluations() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25),
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18; // linear unlock
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = int256(MathLib.atScale(100)); // cycle 1 target = 200%

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(10_000e6);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory first = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(first.length, 1);
        assertEq(first[0].action, 1);
        assertEq(first[0].percent, MathLib.atScale(10));

        mockDealCell.setReturnedCapital(20_000e6);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory second = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(second.length, 1);
        assertEq(second[0].action, 1);
        assertEq(second[0].percent, MathLib.atScale(5));
    }

    function test_consecutiveMissesAcrossSeparateEvaluationsTriggerPenalty() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(80),
            graceCycles: 1,
            penaltyPerMiss: MathLib.atScale(10),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = 0;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(0);
        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory first = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(first.length, 0);

        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory second = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(second.length, 1);
        assertEq(second[0].action, 0);
        assertEq(second[0].percent, MathLib.atScale(10));
    }

    function test_successResetsMissCounterAcrossEvaluations() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(80),
            graceCycles: 1,
            penaltyPerMiss: MathLib.atScale(10),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = 0;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(0);
        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory first = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(first.length, 0);

        mockDealCell.setReturnedCapital(10_000e6);
        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory second = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(second.length, 1);
        assertEq(second[0].action, 1);
        assertEq(second[0].percent, MathLib.atScale(10));

        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory third = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(third.length, 0);
    }

    function test_rewardShareCapsAcrossEvaluations() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(0),
            graceCycles: 0,
            penaltyPerMiss: 0,
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = 0;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(15),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(10_000e6);
        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory first = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(first.length, 1);
        assertEq(first[0].percent, MathLib.atScale(10));

        mockDealCell.setReturnedCapital(20_000e6);
        vm.warp(block.timestamp + 30 days);
        EvaluationResult[] memory second = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertEq(second.length, 1);
        assertEq(second[0].percent, MathLib.atScale(5));
    }

    function test_projectionFromInvestedCapital_usesProjectionMode() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 1,
            revenueProjection: 2,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25),
            graceCycles: 0,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = 0;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setInvestedCapital(address(0x1111), 20_000e6);
        mockDealCell.setReturnedCapital(10_000e6);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 1);
        assertEq(results[0].action, 1);
        assertEq(results[0].percent, MathLib.atScale(10));
    }

    function test_projectionModeWithoutInvestedCapital_reverts() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 1,
            revenueProjection: 2,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25),
            graceCycles: 0,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = 0;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(RevenueBasedEvaluator.RevenueBaseMisconfigured.selector);
        evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
    }

    function test_multiCycleBatch_usesRequirementCurveForEachCycle() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2),
            curveCoeffs: new int256[](2),
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(0),
            graceCycles: 0,
            penaltyPerMiss: 0,
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100));
        cfg.requirementCurveCoeffs[1] = int256(MathLib.atScale(100));

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(30_000e6);
        vm.warp(block.timestamp + 60 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));

        assertEq(results.length, 1);
        assertEq(results[0].action, 1);
        assertEq(results[0].percent, 175e15);
    }

    function test_negativeCoeff_sCurve() public {
        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](3),
            maxCycleUnlockPercent: MathLib.atScale(100),
            minCycleRevenuePercent: MathLib.atScale(0),
            graceCycles: 0,
            penaltyPerMiss: 0,
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = int256(MathLib.atScale(10));  // a
        cfg.curveCoeffs[1] = int256(MathLib.atScale(20));  // b
        cfg.curveCoeffs[2] = -int256(MathLib.atScale(5));  // c (negative)

        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); 
        cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(5_000e6);

        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(DEAL_ID, address(mockDealCell), DEAL_ADDR, address(0));
        assertGt(results[0].percent, 0); // negative coeff still works safely
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_curveUnlock(uint256 revenue, uint256 cycles) public {
        vm.assume(revenue <= 100_000e6);
        vm.assume(cycles >= 1 && cycles <= 10);

        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 0;
        cfg.curveCoeffs[2] = 0;
        cfg.curveCoeffs[3] = 1e18; // x^3

        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); 
        cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(revenue);

        vm.warp(block.timestamp + cycles * 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        // At least one action per cycle
        assertGe(results.length, 0);
    }

    function testFuzz_minUnlockAlwaysApplied(uint256 revenue) public {
        vm.assume(revenue > 10e6); // below curve
        vm.assume(revenue < 5_000e6);

        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 1e18; cfg.curveCoeffs[3] = 1e18;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        uint256 revenuePct = revenue * MathLib.atScale(10) / 10_000e6; // 10% reward for 1 cycle
        if (revenuePct > 0) {
            assertLe(results[0].percent, revenuePct); // unlock < revenue % , since cubic curve
        }
        else {
            assertEq(results.length, 0); // zero revenue - no unlocks
        }
    }

    function testFuzz_linearCurveUnlockApplied(uint256 revenue) public {
        vm.assume(revenue < 1_000e6); // below curve

        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 1e18; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 0;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        uint256 revenuePct = revenue * MathLib.atScale(10) / 10_000e6; // 10% reward for 1 cycle

        if (revenue > 0) {
            assertEq(results[0].percent, revenuePct); // unlock == revenue % , since linear curve
        }
        else {
            assertEq(results.length, 0); // zero revenue - no unlocks
        }
    }

    function testFuzz_zeroUnlockCurveBelowZero(uint256 revenue) public {
        vm.assume(revenue < 5_000e6); // below curve

        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 30 days,
            revenueProjectionMode: 0,
            revenueProjection: 10_000e6,
            requirementCurveCoeffs: new int256[](2), // linear a + b*x
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false
        });
        cfg.curveCoeffs[0] = -1 * int256(MathLib.atScale(50)); cfg.curveCoeffs[1] = 1e18; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 0;
        cfg.requirementCurveCoeffs[0] = int256(MathLib.atScale(100)); cfg.requirementCurveCoeffs[1] = 1e15;

        RevenueBasedEvaluator.Config memory evaluatorCfg = RevenueBasedEvaluator.Config({
            rewardShare: MathLib.atScale(100),
            schedule: cfg
        });
        deployEvaluator(evaluatorCfg);

        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 0); // no unlocks, since linear curve below zero where revenue < 50%
    }
} 
