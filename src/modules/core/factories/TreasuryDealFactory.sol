// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../interfaces/modules/IDealFactory.sol";
import {TreasuryDeal} from "../deals/TreasuryDeal.sol";

contract TreasuryDealFactory is IDealFactory {
    address public immutable PERMIT2;

    constructor(address permit2) {
        PERMIT2 = permit2;
    }

    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken
    ) external returns (address dealAddr) {
        dealAddr = address(
            new TreasuryDeal(
                id,
                dac,
                params.governanceFactory,
                mpToken,
                lpToken,
                params.proposer,
                PERMIT2
            )
        );
    }
}