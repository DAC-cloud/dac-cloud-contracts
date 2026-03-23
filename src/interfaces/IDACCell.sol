// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CapitalCall, ProposalParams, VotingConfig, LegalWrapper} from "./Structs.sol";

interface IDACCell {
    function name() external view returns (string memory);
    function description() external view returns (string memory);

    function getMainToken() external view returns (address);
    function getAgentToken() external view returns (address);
    
    function getDealManager() external view returns (address);
    function getModuleRegistry() external view returns (address);

    function getCapitalCall(bytes32 callHash) external returns (CapitalCall memory call);
    function fulfillCapitalCall(CapitalCall calldata call) external returns (bool);

    function createManagementProposal(ProposalParams calldata params) external returns (uint256 id);
    function executeDACProposal(uint256 id) external;
    
    function getProposalVoting(uint256 proposalId) external view returns (address);
    
    function getVotingConfig() external view returns (VotingConfig memory config);
    function getLegalWrapper() external view returns (LegalWrapper memory wrapper);

    function recoverTreasury(address token) external;

    function logLegalWrapperMessage(bytes4 kind, bytes calldata message) external;
}
