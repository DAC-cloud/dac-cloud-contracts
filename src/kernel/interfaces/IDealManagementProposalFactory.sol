// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "../../interfaces/Structs.sol";

interface IDealManagementProposalFactory {
    function deployProposal(
        uint256 id,
        ProposalParams memory params,
        address dac,
        address deal,
        address token,
        bool vetoEnabled,
        VotingConfig memory votingConfig
    ) external returns (address);
}