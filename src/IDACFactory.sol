// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDACFactory {
    struct DACConfig {
        string symbol;
        string name;
        string description;
        uint256 lpMaxSupply;
        uint256 defaultQuorum;
        address founder;
        uint256 founderLP;
        address treasuryToken;
        uint256 founderCommitment;
    }

    function deployDAC(
        DACConfig calldata config,
        bytes32 salt
    ) external returns (address dacAddr, address lpAddr, address mpAddr);
}