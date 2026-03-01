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
    address public basicEvaluatorFactory;

    error DealKindNotSupported(bytes4 dealKind);
    error EvaluatorKindNotSupported(bytes4 dealKind);

    constructor(
        address _dealCellFactory,
        address _dacDealFactory,
        address _treasuryDealFactory,
        address _basicEvaluatorFactory
    ) ModuleFactory(_dealCellFactory) {
        dacDealFactory = _dacDealFactory;
        treasuryDealFactory = _treasuryDealFactory;
        basicEvaluatorFactory = _basicEvaluatorFactory;
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
            require(false, DealKindNotSupported(dealKind));
        }
    }

    function getEvaluatorFactory(bytes4, bytes4 evaluatorSelector) internal view override returns (IEvaluatorFactory factory) {
        if (evaluatorSelector == CoreEvaluatorType.BASIC_REVENUE_MILESTONES) {
            factory = IEvaluatorFactory(basicEvaluatorFactory);
        }
        
        else {
            require(false, EvaluatorKindNotSupported(evaluatorSelector));
        }
    }
}