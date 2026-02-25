// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../../../interfaces/modules/IDealFactory.sol";
import "../deals/TreasuryDeal.sol";

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
        Deal deal = new TreasuryDeal(
            id,
            dac,
            params.governanceFactory,
            mpToken,
            lpToken,
            params.proposer,
            PERMIT2
        );

        dealAddr = address(deal);
    }
}