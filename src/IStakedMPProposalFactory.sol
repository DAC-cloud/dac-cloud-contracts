// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

interface IStakedMPProposalFactory {
    function deployProposal(
        uint256 id,
        StakedMPParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address);
}