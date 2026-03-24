// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACConfig, ExistingDACConfig} from "./Structs.sol";

interface IDACFactory {
    
    function deployDAC(
        DACConfig calldata config,
        bytes32 salt,
        address deferBirthRole
    ) external returns (
        address dacAddr, 
        address mainTokenAddr, 
        address agentTokenAddr
    );

    function startDAC(
        address dacCell,
        DACConfig calldata config,
        address mainTokenAddr,
        address agentTokenAddr
    ) external;

    function deployExistingTokenDAC(
        bytes calldata encodedConfig,
        bytes32 salt
    ) external returns (
        address dacAddr,
        address wrappedMainTokenAddr,
        address agentTokenAddr,
        address governanceOracleAddr
    );
}
