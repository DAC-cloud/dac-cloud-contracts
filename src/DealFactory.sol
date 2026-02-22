// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DACDeal.sol";
import "./Interfaces.sol";
import "./IEvaluatorFactory.sol";

contract DealFactory {
    //todo: mapping of trusted governance factories

    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr, address evaluatorAddr) {
        //todo: select a proper deal by params.dealKind

        //todo: check if governance factory is trusted and matching the deal type

        //todo: predict deal address, create a new dac

        Deal deal = new DACDeal(
            id,
            dac,
            params.governanceFactory,
            //params.dealTarget,
            mpToken,
            lpToken,
            params.proposer
        );

        deal.initialize(params, votingConfig);
        
        // Create per-deal evaluator instance
        evaluatorAddr = IEvaluatorFactory(params.evaluatorFactory)
            .deployEvaluator(params.dealKind, params.evaluatorConfig);

        dealAddr = address(deal);
    }
}