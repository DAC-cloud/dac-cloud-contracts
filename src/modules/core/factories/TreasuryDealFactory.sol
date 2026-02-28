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
        address dealCell,
        DealParams calldata params,
        address dac,
        address agentToken,
        address mainToken
    ) external returns (address dealAddr) {
        dealAddr = address(
            new TreasuryDeal(
                id,
                dac,
                params.governanceFactory,
                agentToken,
                mainToken,
                params.proposer,
                PERMIT2
            )
        );

        TreasuryDeal(dealAddr).initialize(dealCell);
    }
}