// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";
import "./Interfaces.sol";

contract DealFactory {
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken,
        address votingFactory
    ) external returns (address) {
        Deal deal = new Deal(id, dac, params.dealTarget, mpToken, lpToken, votingFactory);
        deal.initialize(params);
        return address(deal);
    }
}