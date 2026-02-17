// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

interface IDACEntity {
    function fulfillCapitalCall(CapitalCall calldata call) external returns (bool);
    function createLPManagementProposal(LPMParams calldata params) external returns (uint256 id);
    function getProposalVoting(uint256 proposalId) external view returns (address);
    function getQuorumPercent() external view returns (uint256);
    function getTreasuryBalance(address token) external view returns (uint256);
    function getLPToken() external view returns (address);

    struct Config {
        uint256 quorumPercent;
        address lpToken;
        address mpToken;
        address votingFactory;
        address dealFactory;
        address lpFactory;
    }
}