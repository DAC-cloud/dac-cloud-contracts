// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvaluationResult} from "./Structs.sol";

interface IEvaluator {
    function permitMint(
        address deal, 
        address to, 
        uint256 amount
    ) external returns (bool permit);
    
    function evaluateDeal(
        uint256 dealId, 
        address dealCell, 
        address dealAddr, 
        address managerAddr
    ) external returns (EvaluationResult[] memory);
}

/// Optional. The kernel calls it once, when the DAC approves the deal, on every evaluator
/// attached at that moment, so an evaluator can take its baselines (reference prices,
/// schedule start) at activation rather than at proposal time. The hook runs with all the
/// gas the approval carries, without a fixed limit. An evaluator without the hook, or one
/// whose hook reverts for a reason of its own, does not affect the approval: the kernel
/// emits `EvaluatorActivationSkipped` and goes on, so such an evaluator should be able to
/// take its baselines later by itself. A hook that fails by running out of gas reverts the
/// whole approval instead; a hook that can never finish within a transaction therefore
/// keeps its own deal from being approved. A hook that makes external calls and catches
/// their failures must check for itself that a caught failure was not a lack of gas.
/// An evaluator added to a deal that is already live takes its baselines when it is created.
interface IEvaluatorActivation {
    function onDealActivated() external;
}
