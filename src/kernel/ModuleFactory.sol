// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IModuleFactory.sol";
import "../interfaces/modules/IDealFactory.sol";
import "../interfaces/modules/IEvaluatorFactory.sol";
import "./Deal.sol";

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
        address mpToken,
        address lpToken,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr, address evaluatorAddr) {
        IDealFactory factory = getDealFactory(params.dealKind);

        dealAddr = factory.deployDeal(
            id,
            params,
            dac,
            mpToken,
            lpToken
        );

        Deal(dealAddr).initialize(params, votingConfig);
        
        IEvaluatorFactory evaluatorFactory = getEvaluatorFactory(params.dealKind, params.evaluatorSelector);

        evaluatorAddr = evaluatorFactory.deployEvaluator(dac, id, params);
    }
}