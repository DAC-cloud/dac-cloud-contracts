// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACConfig} from "./Structs.sol";

interface IDACFactory {
    
    function deployDAC(
        DACConfig calldata config,
        bytes32 salt
    ) external returns (
        address dacAddr, 
        address mainTokenAddr, 
        address agentTokenAddr
    );
}