// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDealFactory} from "../../interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../../interfaces/modules/IEvaluatorFactory.sol";
import {ModuleFactory} from "../../kernel/ModuleFactory.sol";
import {CoreDealType, CoreEvaluatorType} from "./CoreModuleDeals.sol";

contract CoreModuleFactory is ModuleFactory {
    bytes32 internal constant MODULE_ID = bytes32("dac.core");
    uint32 internal constant MODULE_MAJOR = 1;
    uint32 internal constant MODULE_MINOR = 0;
    uint32 internal constant MODULE_PATCH = 0;
    string internal constant MODULE_MANIFEST_URI = "";

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

    function moduleId() external pure returns (bytes32) { return MODULE_ID; }

    function moduleVersion() external pure returns (uint32 major, uint32 minor, uint32 patch) {
        return (MODULE_MAJOR, MODULE_MINOR, MODULE_PATCH);
    }

    function moduleManifestURI() external pure returns (string memory) { return MODULE_MANIFEST_URI; }

    function supportedDealKinds() external pure returns (bytes4[] memory kinds) {
        kinds = new bytes4[](2);
        kinds[0] = CoreDealType.DAC_DEAL;
        kinds[1] = CoreDealType.PERMIT2_TREASURY;
    }

    function supportedEvaluatorKinds() external pure returns (bytes4[] memory kinds) {
        kinds = new bytes4[](2);
        kinds[0] = CoreEvaluatorType.MILESTONES_EVALUATOR;
        kinds[1] = CoreEvaluatorType.REVENUE_EVALUATOR;
    }

    function supportsDealKind(bytes4 dealKind) external pure returns (bool) {
        return dealKind == CoreDealType.DAC_DEAL || dealKind == CoreDealType.PERMIT2_TREASURY;
    }

    function supportsEvaluatorKind(bytes4, bytes4 evaluatorKind) external pure returns (bool) {
        return evaluatorKind == CoreEvaluatorType.MILESTONES_EVALUATOR
            || evaluatorKind == CoreEvaluatorType.REVENUE_EVALUATOR;
    }

    function supportsDealRewardPool(bytes4 dealKind) external pure returns (bool) {
        return dealKind == CoreDealType.DAC_DEAL || dealKind == CoreDealType.PERMIT2_TREASURY;
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
