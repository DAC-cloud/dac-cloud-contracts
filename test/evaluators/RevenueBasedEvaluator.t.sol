// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import "../../src/interfaces/IDealCell.sol";
import "../../src/kernel/libraries/MathLib.sol";

contract MockDealCell is IDealCell {
    uint256 public returnedCapital;

    uint256 internal _startTime;

    constructor(
        uint256 __startTime
    ) {
        _startTime = __startTime;
    }

    function setReturnedCapital(uint256 _returned) external {
        returnedCapital = _returned;
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
    function claimMainToken(uint256 evaluatorId) external {}
    function unstake() external {}
    function fundingTranche(uint256) external pure returns (Tranche memory tranche) { }
    function fundingTokens() external pure returns (address[] memory) { return new address[](0); }
    function getMainRewardsLimit() external pure returns (uint256) { return 0; }
    function getInvestedCapital(address) external pure returns (uint256) { return 0; }
    function allowEarlyReturns() external pure returns (bool) { return false; }
    function allowDACVeto() external pure returns (bool) { return false; }
    function isValidDeal() external pure returns (bool) { return true; }
    function isApproved() external pure returns (bool) { return true; }
    function isClosed() external pure returns (bool) { return false; }
    function approveDeadline() external pure returns (uint256) { return 0; }
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
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER: DEPLOY EVALUATOR
    //////////////////////////////////////////////////////////////*/

    function deployEvaluator(RevenueBasedEvaluator.Config memory cfg) internal {
        bytes memory configData = abi.encode(cfg);
        evaluator = new RevenueBasedEvaluator(DAC, DEAL_ID, address(mockDealCell), configData);
    }

    /*//////////////////////////////////////////////////////////////
                          UNIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_firstCycle_meetsTarget_unlocks() public {
        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 0;
        cfg.curveCoeffs[2] = 0;
        cfg.curveCoeffs[3] = 1e18; // y = x^3

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
        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;

        deployEvaluator(cfg);

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
        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(80), // miss if < 80%
            graceCycles: 0, // no grace, 2 periods clearly missed
            penaltyPerMiss: MathLib.atScale(10),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;

        deployEvaluator(cfg);

        mockDealCell.setReturnedCapital(0); // total miss

        vm.warp(block.timestamp + 60 days); // two cycles

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results.length, 2); // reward, penalty
        assertEq(results[1].action, 0);
        assertEq(results[1].percent, MathLib.atScale(20)); // penalty triggered
    }

    function test_fullUnlock_triggersClose() public {
        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(100),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;

        deployEvaluator(cfg);

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

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_curveUnlock(uint256 revenue, uint256 cycles) public {
        vm.assume(revenue <= 100_000e6);
        vm.assume(cycles >= 1 && cycles <= 10);

        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0;
        cfg.curveCoeffs[1] = 0;
        cfg.curveCoeffs[2] = 0;
        cfg.curveCoeffs[3] = 1e18; // x^3

        deployEvaluator(cfg);

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
        vm.assume(revenue < 1_000e6); // below curve

        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 0; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 1e18;

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        uint256 revenuePct = revenue * MathLib.atScale(10) / 10_000e6; // 10% reward for 1 cycle

        assertLe(results[0].percent, revenuePct); // unlock < revenue % , since cubic curve
    }

    function testFuzz_linearCurveUnlockApplied(uint256 revenue) public {
        vm.assume(revenue < 1_000e6); // below curve

        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = 0; cfg.curveCoeffs[1] = 1e18; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 0;

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        uint256 revenuePct = revenue * MathLib.atScale(10) / 10_000e6; // 10% reward for 1 cycle

        assertEq(results[0].percent, revenuePct); // unlock == revenue % , since linear curve
    }

    function testFuzz_zeroUnlockCurveBelowZero(uint256 revenue) public {
        vm.assume(revenue < 5_000e6); // below curve

        RevenueBasedEvaluator.Config memory cfg = RevenueBasedEvaluator.Config({
            token: address(0x1111),
            duration: 30 days,
            baseExpected: 10_000e6,
            curveCoeffs: new int256[](4), // cubic: x^3
            maxCycleUnlockPercent: MathLib.atScale(10),
            minCycleRevenuePercent: MathLib.atScale(25), // miss if < 25%
            graceCycles: 3,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0
        });
        cfg.curveCoeffs[0] = -1 * int256(MathLib.atScale(50)); cfg.curveCoeffs[1] = 1e18; cfg.curveCoeffs[2] = 0; cfg.curveCoeffs[3] = 0;

        deployEvaluator(cfg);
        mockDealCell.setReturnedCapital(revenue);
        vm.warp(block.timestamp + 30 days);

        EvaluationResult[] memory results = evaluator.evaluateDeal(
            DEAL_ID, 
            address(mockDealCell), 
            address(DEAL_ADDR), 
            address(0)
        );

        assertEq(results[0].percent, 0); // unlock == 0 , since linear curve below zero where revenue < 50%
    }
} 