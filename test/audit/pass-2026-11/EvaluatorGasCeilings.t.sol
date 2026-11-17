// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Review 2026-11 (see audit.md, section 7). Gas measurement harness, not an assertion
// suite: it prints the figures behind the gas tables. Run with --isolate so every top-level
// call is its own transaction (cold storage), and size it through the environment, e.g.
//   N_HOLDERS=100 K_RESULTS=10 forge test --match-path 'test/audit/pass-2026-11/*GasCeilings*' --isolate -vv
// Variables: N_HOLDERS, K_RESULTS, N_COEFFS, DESC_BYTES, AGENTS_LIMIT.

import "forge-std/Test.sol";
import {DealParams, EvaluationResult} from "../../../src/interfaces/Structs.sol";
import {IDACCell} from "../../../src/interfaces/IDACCell.sol";
import {MathLib} from "../../../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../../../src/modules/core/CoreModuleDeals.sol";
import {RevenueBasedEvaluator} from "../../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {MilestoneBasedEvaluator} from "../../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {RevenueEvaluatorFactory} from "../../../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {MilestoneEvaluatorFactory} from "../../../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueSchedule, Milestone} from "../../../src/modules/core/interfaces/Structs.sol";
import {MockDealCell} from "../../evaluators/RevenueBasedEvaluator.t.sol";

/// Gas of a full 64-cycle revenue evaluation as a function of curve length. Run with --isolate.
contract EvaluatorGasCeilingsTest is Test {
    address constant DAC = address(0xDAC);

    function _lastGas() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok, "lastCallGas failed");
        (, uint64 total,,,) = abi.decode(ret, (uint64, uint64, uint64, int64, uint64));
        used = total;
    }

    function _dealParams(bytes memory configData, bytes4 selector) internal view returns (DealParams memory) {
        return DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Gas",
            description: "Gas",
            linkHash: "0x00",
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
            evaluatorSelector: selector,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: configData,
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
    }

    function test_gas_revenue64Cycles() public {
        uint256 coeffs = vm.envOr("N_COEFFS", uint256(4));

        RevenueEvaluatorFactory factory = new RevenueEvaluatorFactory();
        MockDealCell cell = new MockDealCell(block.timestamp);
        vm.mockCall(DAC, abi.encodeWithSelector(IDACCell.getDealManager.selector), abi.encode(address(this)));

        RevenueSchedule memory cfg = RevenueSchedule({
            token: address(0x1111),
            duration: 1 days,
            revenueProjectionMode: 0,
            revenueProjection: 100e6,
            requirementCurveCoeffs: new int256[](coeffs),
            curveCoeffs: new int256[](coeffs),
            maxCycleUnlockPercent: MathLib.atScale(1),
            minCycleRevenuePercent: MathLib.atScale(50),
            graceCycles: 0,
            penaltyPerMiss: MathLib.atScale(5),
            evaluationStart: 0,
            autoClose: false,
            excludePrincipal: false
        });
        // non-trivial but tiny higher-order terms so every Horner step does real work
        for (uint256 i = 0; i < coeffs; i++) {
            cfg.curveCoeffs[i] = i == 1 ? int256(1e18) : int256(1);
            cfg.requirementCurveCoeffs[i] = i == 0 ? int256(1e18) : int256(0);
        }

        bytes memory configData =
            abi.encode(RevenueBasedEvaluator.Config({rewardShare: MathLib.atScale(100), schedule: cfg}));
        RevenueBasedEvaluator evaluator = RevenueBasedEvaluator(
            factory.deployEvaluator(
                DAC, 1, address(cell), _dealParams(configData, CoreEvaluatorType.REVENUE_EVALUATOR), configData
            )
        );
        uint256 deployGas = _lastGas();

        cell.setReturnedCapital(100e6);

        // one cycle
        vm.warp(block.timestamp + 1 days);
        evaluator.evaluateDeal(1, address(cell), address(0xDEA1), address(0));
        uint256 oneCycle = _lastGas();

        // 64+ cycles at once
        cell.setReturnedCapital(100e6 + 100 * 100e6);
        vm.warp(block.timestamp + 100 days);
        evaluator.evaluateDeal(1, address(cell), address(0xDEA1), address(0));
        uint256 sixtyFour = _lastGas();

        emit log_named_uint("N_COEFFS (each curve)", coeffs);
        emit log_named_uint("gas deployEvaluator", deployGas);
        emit log_named_uint("gas evaluateDeal 1 cycle", oneCycle);
        emit log_named_uint("gas evaluateDeal 64 cycles", sixtyFour);
    }
}
