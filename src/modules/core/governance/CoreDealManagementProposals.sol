// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICoreDealManagementProposals {
    // DAC deal
    function reinvestProfits() external pure returns (bytes4);
    function createDACManagementProposal() external pure returns (bytes4);
    function voteDACManagementProposal() external pure returns (bytes4);

    // Treasury deal
    function directSpend() external pure returns (bytes4);
    function approvePermit2Spend() external pure returns (bytes4);
    function approveAgentSpend() external pure returns (bytes4);
    function assignClaimer() external pure returns (bytes4);
    function returnCapitalToDAC() external pure returns (bytes4);
}

library CoreDealManagementType {
    bytes4 public constant REINVEST_PROFITS      = ICoreDealManagementProposals.reinvestProfits.selector;               // High quorum
    bytes4 public constant CREATE_DAC_PROPOSAL   = ICoreDealManagementProposals.createDACManagementProposal.selector;   // Default quorum
    bytes4 public constant VOTE_DAC_PROPOSAL     = ICoreDealManagementProposals.voteDACManagementProposal.selector;     // Default quorum, blocking allowed

    bytes4 public constant APPROVE_DIRECT_SPEND  = ICoreDealManagementProposals.directSpend.selector;                   // High quorum
    bytes4 public constant APPROVE_PERMIT2_SPEND = ICoreDealManagementProposals.approvePermit2Spend.selector;           // Default quorum, blocking allowed
    bytes4 public constant APPROVE_AGENT_SPEND   = ICoreDealManagementProposals.approveAgentSpend.selector;             // Default quorum, blocking allowed
    bytes4 public constant ASSIGN_CLAIMER        = ICoreDealManagementProposals.assignClaimer.selector;                 // Default quorum
    bytes4 public constant RETURN_CAPITAL_TO_DAC = ICoreDealManagementProposals.returnCapitalToDAC.selector;            // Default quorum
}
