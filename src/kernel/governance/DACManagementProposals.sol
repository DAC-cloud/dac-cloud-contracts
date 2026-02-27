// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDACManagementProposals {
    function updateVotingConfig() external pure returns (bytes4);

    function updateLegalWrapper() external pure returns (bytes4);
    function approveOffchainAction() external pure returns (bytes4);

    function mintToken() external pure returns (bytes4);
    function burnToken() external pure returns (bytes4);

    function mintAgentToken() external pure returns (bytes4);
    function revokeAgentToken() external pure returns (bytes4);

    function toggleDividends() external pure returns (bytes4);
    function dividendPayout() external pure returns (bytes4);

    function capitalCall() external pure returns (bytes4);

    function addModuleFactory() external pure returns (bytes4);
    function removeModuleFactory() external pure returns (bytes4);

    function approveDeal() external pure returns (bytes4);
    function approveTranche() external pure returns (bytes4);

    function recoverDeal() external pure returns (bytes4);

    function passDealMessage() external pure returns (bytes4);
    function castVetoForDealProposal() external pure returns (bytes4);
}

library DACManagementProposalType {
    bytes4 public constant UPDATE_VOTING_CONFIG     = IDACManagementProposals.updateVotingConfig.selector;      // High quorum
    bytes4 public constant UPDATE_LEGAL_WRAPPER     = IDACManagementProposals.updateLegalWrapper.selector;      // High quorum
    bytes4 public constant APPROVE_OFFCHAIN_ACTION  = IDACManagementProposals.approveOffchainAction.selector;   // Default quorum, blocking allowed

    bytes4 public constant MINT_MAIN_TOKENS         = IDACManagementProposals.mintToken.selector;               // High quorum
    bytes4 public constant BURN_MAIN_TOKENS         = IDACManagementProposals.burnToken.selector;               // Default quorum, blocking allowed
    bytes4 public constant MINT_AGENT_TOKENS        = IDACManagementProposals.mintAgentToken.selector;          // Default quorum
    bytes4 public constant REVOKE_AGENT_TOKENS      = IDACManagementProposals.revokeAgentToken.selector;        // Default quorum, blocking allowed

    bytes4 public constant CAPITAL_CALL             = IDACManagementProposals.capitalCall.selector;             // Default quorum, blocking allowed

    // ** Turning on dividends for the DAC-cell have a very strong legal consequences! **
    //
    // It will likely lead to LP-token being classified as an unregulated security,
    //  especially if at any point in time it was held by or was offered to the general public.
    //
    // Therefore, toggling dividends on the running DAC is ONLY possible with the explicit authorization
    //  indicated by the legal wrapper.
    // Authorization of the legal wrapper is indicated by legal wrapper himself executing the proposal
    //  with `msg.sender == legalWrapper.wrapperAddr`.
    //
    // The only way to set dividend mechanics without a legal wrapper is when creating a new DAC in the DAC factory.
    //
    // Do not turn on dividends on the already running DAC unless you 100% know what you are doing, 
    //  understand all legal implications of this bold action, have a legal counsel proficient in 
    //  international securities regulations, and are ready at any point order additional consulting 
    //  and representation from highly-qualified lawyers and advocates.
    bytes4 public constant TOGGLE_DIVIDENDS = IDACManagementProposals.toggleDividends.selector;                 // High quorum
    
    bytes4 public constant DIVIDEND_PAYOUT  = IDACManagementProposals.dividendPayout.selector;                  // High quorum
    
    bytes4 public constant APPROVE_DEAL     = IDACManagementProposals.approveDeal.selector;                     // Default quorum, blocking allowed
    bytes4 public constant APPROVE_TRANCHE  = IDACManagementProposals.approveTranche.selector;                  // Default quorum, blocking allowed
    
    // If legal wrapper is set, will require legal wrapper address execution
    bytes4 public constant RECOVER_DEAL     = IDACManagementProposals.recoverDeal.selector;                     // Default quorum
    
    bytes4 public constant DEAL_MESSAGE     = IDACManagementProposals.passDealMessage.selector;                 // Default quorum
    bytes4 public constant CAST_VETO_DEAL   = IDACManagementProposals.castVetoForDealProposal.selector;         // Default quorum

    bytes4 public constant ADD_MODULE       = IDACManagementProposals.addModuleFactory.selector;                // High quorum

    // If the legal wrapper is set, executing this proposal will require explicit legal wrapper authorization.
    // Authorization of the legal wrapper is indicated by legal wrapper himself executing the proposal.
    bytes4 public constant REMOVE_MODULE    = IDACManagementProposals.removeModuleFactory.selector;             // High quorum
}
