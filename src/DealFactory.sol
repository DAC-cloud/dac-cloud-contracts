// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";

contract DealFactory {
    function deployDeal(
        uint256 id,
        string memory description,
        address dac,
        address childDAC,
        uint256 fundingAmount,
        address fundingToken,
        uint256 successThreshold,
        uint256 duration,
        address mpToken,
        address votingFactory,
        uint256 lpAmount
    ) external returns (address) {
        Deal deal = new Deal(id, description, dac, childDAC, fundingAmount, fundingToken, successThreshold, duration, mpToken, votingFactory, lpAmount);
        return address(deal);
    }
}