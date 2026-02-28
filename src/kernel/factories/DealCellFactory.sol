// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealCell} from "../DealCell.sol";

library DealCellFactory {
    function deployCell(
        uint256 id,
        address dac,
        address _dealManager,
        address governanceFactory,
        address agentToken,
        address mainToken,
        address proposer
    ) public returns (address dacAddr) {
        dacAddr = address(
            new DealCell(
                id,
                dac,
                _dealManager,
                governanceFactory,
                agentToken,
                mainToken,
                proposer
            )
        );
    }
}