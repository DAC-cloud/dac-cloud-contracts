// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDealFactory} from "../../interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../../interfaces/modules/IEvaluatorFactory.sol";
import {ModuleFactory} from "../../kernel/ModuleFactory.sol";
import {CoreDealType, CoreEvaluatorType} from "./CoreModuleDeals.sol";

contract CoreModuleFactory is ModuleFactory {

    // Deals
    address public dacDealFactory;
    address public treasuryDealFactory;

    // Evaluators
    address public milestoneEvaluatorFactory;
    address public revenueEvaluatorFactory;

    error DealKindNotSupported(bytes4 dealKind);
    error EvaluatorKindNotSupported(bytes4 dealKind);

    constructor(
        address _dealCellFactory,
        address _dacDealFactory,
        address _stakedAgentTokenFactory,
        address _treasuryDealFactory,
        address _milestoneEvaluatorFactory,
        address _revenueEvaluatorFactory
    ) ModuleFactory(_dealCellFactory, _stakedAgentTokenFactory) {
        dacDealFactory = _dacDealFactory;
        treasuryDealFactory = _treasuryDealFactory;
        milestoneEvaluatorFactory = _milestoneEvaluatorFactory;
        revenueEvaluatorFactory = _revenueEvaluatorFactory;
    }

    function isActive() external pure returns (bool) { return true; }
    function safetyCheck(address) external pure returns (bool) { return true; }

    function getDealFactory(bytes4 dealKind) internal view override returns (IDealFactory factory) {
        if (dealKind == CoreDealType.DAC_DEAL) {
            factory = IDealFactory(dacDealFactory);
        }
        
        else if (dealKind == CoreDealType.PERMIT2_TREASURY) {
            factory = IDealFactory(treasuryDealFactory);
        }

        else {
            revert DealKindNotSupported(dealKind);
        }
    }

    function getEvaluatorFactory(bytes4, bytes4 evaluatorSelector) internal view override returns (IEvaluatorFactory factory) {
        if (evaluatorSelector == CoreEvaluatorType.MILESTONES_EVALUATOR) {
            factory = IEvaluatorFactory(milestoneEvaluatorFactory);
        }
        
        else if (evaluatorSelector == CoreEvaluatorType.REVENUE_EVALUATOR) {
            factory = IEvaluatorFactory(revenueEvaluatorFactory);
        }

        else {
            revert EvaluatorKindNotSupported(evaluatorSelector);
        }
    }
}