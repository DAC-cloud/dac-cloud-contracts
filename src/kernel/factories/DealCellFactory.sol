// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IDACFactory.sol";
import "../DealCell.sol";

library DealCellFactory {
    function deployCell(
        uint256 id,
        address dac,
        address governanceFactory,
        address agentToken,
        address mainToken,
        address proposer
    ) public returns (address dacAddr) {
        dacAddr = address(
            new DealCell(
                id,
                dac,
                governanceFactory,
                agentToken,
                mainToken,
                proposer
            )
        );
    }
}