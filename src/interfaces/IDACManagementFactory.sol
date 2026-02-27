// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "./Structs.sol";

interface IDACManagementFactory {
    function deployProposal(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address token,
        uint256 unreleasedBalance,
        VotingConfig calldata votingConfig
    ) external returns (address);
}
