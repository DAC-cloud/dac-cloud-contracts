// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../interfaces/modules/IDealFactory.sol";
import {DACDeal} from "../deals/DACDeal.sol";

contract DACDealFactory is IDealFactory {
    
    function deployDeal(
        uint256 id,
        address dealCell,
        DealParams calldata params,
        address dac,
        address agentToken,
        address mainToken
    ) external returns (address dealAddr) {
        dealAddr = address(
            new DACDeal(
                id,
                dac,
                params.governanceFactory,
                agentToken,
                mainToken,
                params.proposer
            )
        );

        DACDeal(dealAddr).initialize(dealCell);
    }
}