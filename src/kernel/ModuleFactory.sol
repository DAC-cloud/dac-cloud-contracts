// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig} from "../interfaces/Structs.sol";
import {IModuleFactory} from "../interfaces/IModuleFactory.sol";
import {IDealFactory} from "../interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../interfaces/modules/IEvaluatorFactory.sol";
import {IDACCellAdapter} from "./interfaces/IDACCellAdapter.sol";

abstract contract ModuleFactory is IModuleFactory {

    function getDealFactory(
        bytes4 dealKind
    ) internal virtual returns (IDealFactory);

    function getEvaluatorFactory(
        bytes4 dealKind,
        bytes4 evaluatorSelector
    ) internal virtual returns (IEvaluatorFactory);

    // Deploys only the Deal contract. DealCell deployment and initialization
    // are handled by the kernel for security (no module control over DealCell).
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address dealCell,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr) {
        IDealFactory factory = getDealFactory(params.dealKind);
        dealAddr = factory.deployDeal(
            id,
            dealCell,
            params,
            dac,
            IDACCellAdapter(dac).getAgentToken(),
            IDACCellAdapter(dac).getMainToken()
        );
    }

    function deployEvaluator(
        address dac,
        uint256 id,
        address dealCell,
        DealParams calldata params,
        bytes4 evaluatorSelector,
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr) {
        IEvaluatorFactory evaluatorFactory = getEvaluatorFactory(params.dealKind, evaluatorSelector);

        evaluatorAddr = evaluatorFactory.deployEvaluator(dac, id, dealCell, params, evaluatorConfig);
    }
}
