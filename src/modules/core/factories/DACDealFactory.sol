// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../interfaces/modules/IDealFactory.sol";
import {DACDeal} from "../deals/DACDeal.sol";

contract DACDealFactory is IDealFactory {
    
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken
    ) external returns (address dealAddr) {
        dealAddr = address(
            new DACDeal(
                id,
                dac,
                params.governanceFactory,
                mpToken,
                lpToken,
                params.proposer
            )
        );
    }
}