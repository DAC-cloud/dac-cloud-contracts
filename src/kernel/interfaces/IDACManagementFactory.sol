// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";

interface IDACManagementFactory {
    function deployProposal(
        uint256 id,
        ProposalParams memory params,
        address dac,
        address token,
        uint256 totalVotingSupply,
        VotingConfig memory votingConfig
    ) external returns (address);
}
