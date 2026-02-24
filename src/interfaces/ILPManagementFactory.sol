// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface ILPManagementFactory {
    function deployLPManagement(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address);
}
