// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig} from "../interfaces/Structs.sol";
import {IModuleFactory} from "../interfaces/IModuleFactory.sol";
import {IDealFactory} from "../interfaces/modules/IDealFactory.sol";
import {IEvaluatorFactory} from "../interfaces/modules/IEvaluatorFactory.sol";
import {DealCellFactory} from "./factories/DealCellFactory.sol";
import {DealCell} from "./DealCell.sol";
import {Deal} from "./Deal.sol";

abstract contract ModuleFactory is IModuleFactory {
    function getDealFactory(
        bytes4 dealKind
    ) internal virtual returns (IDealFactory);

    function getEvaluatorFactory(
        bytes4 dealKind, 
        bytes4 evaluatorSelector
    ) internal virtual returns (IEvaluatorFactory);

    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mainToken,
        address agentToken,
        VotingConfig calldata votingConfig
    ) external returns (address dealCell, address dealAddr, address evaluatorAddr) {
        dealCell = DealCellFactory.deployCell(
            id,
            dac,
            params.governanceFactory,
            agentToken,
            mainToken,
            params.proposer
        );

        IDealFactory factory = getDealFactory(params.dealKind);
        dealAddr = factory.deployDeal(
            id,
            params,
            dac,
            agentToken,
            mainToken
        );

        DealCell(dealCell).initialize(params, votingConfig);

        IEvaluatorFactory evaluatorFactory = getEvaluatorFactory(params.dealKind, params.evaluatorSelector);

        evaluatorAddr = evaluatorFactory.deployEvaluator(dac, id, dealCell, params);
    }
}