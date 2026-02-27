// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACCell} from "../DACCell.sol";

library DACCellFactory {

    function deployDAC(
        bytes32 salt,
        string calldata name,
        string calldata description,
        address governanceFactory
    ) external returns (address dacAddr) {
        dacAddr = address(
            new DACCell{salt: salt}(
                name,
                description,
                governanceFactory
            )
        );
    }
}