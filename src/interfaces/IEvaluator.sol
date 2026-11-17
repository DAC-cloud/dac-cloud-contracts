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
/// schedule start) at activation rather than at proposal time. The call is isolated and
/// gas-capped: an evaluator without the hook, or one whose hook fails, does not affect the
/// approval. An evaluator added to a deal that is already live takes its baselines when it
/// is created.
interface IEvaluatorActivation {
    function onDealActivated() external;
}
