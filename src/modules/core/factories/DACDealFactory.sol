// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../../../interfaces/modules/IDealFactory.sol";
import "../deals/DACDeal.sol";

contract DACDealFactory is IDealFactory {
    
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken
    ) external returns (address dealAddr) {
        Deal deal = new DACDeal(
            id,
            dac,
            params.governanceFactory,
            mpToken,
            lpToken,
            params.proposer
        );

        dealAddr = address(deal);
    }
}