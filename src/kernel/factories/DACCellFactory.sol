// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IDACFactory.sol";
import "../DACCell.sol";

contract DACCellFactory {

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