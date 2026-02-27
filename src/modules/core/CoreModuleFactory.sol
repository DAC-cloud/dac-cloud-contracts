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

    constructor(
        address _dacDealFactory,
        address _treasuryDealFactory,
        address _basicEvaluatorFactory
    ) {
        dacDealFactory = _dacDealFactory;
        treasuryDealFactory = _treasuryDealFactory;
        basicEvaluatorFactory = _basicEvaluatorFactory;
    }

    function isActive() external pure returns (bool) { return true; }
    function safetyCheck(address) external pure returns (bool) { return true; }

    function getDealFactory(bytes4 dealKind) internal override returns (IDealFactory) {
        //todo: select deal factory
    }

    function getEvaluatorFactory(bytes4 dealKind, bytes4 evaluatorSelector) internal override returns (IEvaluatorFactory) {
        //todo: select deal factory
    }
}