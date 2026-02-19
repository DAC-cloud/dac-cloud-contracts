// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";
import "./Interfaces.sol";
import "./IEvaluatorFactory.sol";

contract DealFactory {
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken,
        address votingFactory,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr, address evaluatorAddr) {
        Deal deal = new Deal(
            id,
            dac,
            params.dealTarget,
            mpToken,
            lpToken,
            votingFactory,
            params.proposer,
            params.isWhitelistOnly
        );

        deal.initialize(params, votingConfig);
        
        // Create per-deal evaluator instance
        evaluatorAddr = IEvaluatorFactory(params.evaluatorFactory)
            .deployEvaluator(params.evaluatorConfig);

        dealAddr = address(deal);
    }
}