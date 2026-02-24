// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface IDACEntity {
    function getCapitalCall(bytes32 callHash) external returns (CapitalCall memory call);
    function fulfillCapitalCall(CapitalCall calldata call) external returns (bool);
    function createLPManagementProposal(ProposalParams calldata params) external returns (uint256 id);
    function getProposalVoting(uint256 proposalId) external view returns (address);
}