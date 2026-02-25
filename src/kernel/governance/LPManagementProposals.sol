// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagementProposals {
    function updateVotingConfig() external pure returns (bytes4);

    function updateLegalWrapper() external pure returns (bytes4);
    function approveOffchainAction() external pure returns (bytes4);

    function mintLP() external pure returns (bytes4);
    function burnLP() external pure returns (bytes4);

    function mintMP() external pure returns (bytes4);
    function revokeMP() external pure returns (bytes4);

    function toggleDividends() external pure returns (bytes4);
    function dividendPayout() external pure returns (bytes4);

    function capitalCall() external pure returns (bytes4);

    function addModuleFactory() external pure returns (bytes4);
    function removeModuleFactory() external pure returns (bytes4);

    function approveDeal() external pure returns (bytes4);
    function approveTranche() external pure returns (bytes4);

    function recoverDeal() external pure returns (bytes4);

    function passDealMessage() external pure returns (bytes4);
}

library LPManagementProposalType {
    bytes4 public constant UPDATE_VOTING_CONFIG     = IManagementProposals.updateVotingConfig.selector;      // High quorum
    bytes4 public constant UPDATE_LEGAL_WRAPPER     = IManagementProposals.updateLegalWrapper.selector;      // High quorum
    bytes4 public constant APPROVE_OFFCHAIN_ACTION  = IManagementProposals.approveOffchainAction.selector;   // Default quorum, blocking allowed

    bytes4 public constant MINT_LP_TOKENS   = IManagementProposals.mintLP.selector;             // High quorum
    bytes4 public constant BURN_LP_TOKENS   = IManagementProposals.burnLP.selector;             // Default quorum, blocking allowed
    bytes4 public constant MINT_MP_TOKENS   = IManagementProposals.mintMP.selector;             // Default quorum
    bytes4 public constant REVOKE_MP_TOKENS = IManagementProposals.revokeMP.selector;           // Default quorum, blocking allowed

    bytes4 public constant CAPITAL_CALL     = IManagementProposals.capitalCall.selector;        // Default quorum, blocking allowed

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
    bytes4 public constant TOGGLE_DIVIDENDS = IManagementProposals.toggleDividends.selector;    // High quorum
    
    bytes4 public constant DIVIDEND_PAYOUT  = IManagementProposals.dividendPayout.selector;     // High quorum
    
    bytes4 public constant APPROVE_DEAL     = IManagementProposals.mintLP.selector;             // Default quorum, blocking allowed
    bytes4 public constant APPROVE_TRANCHE  = IManagementProposals.mintMP.selector;             // Default quorum, blocking allowed
    bytes4 public constant RECOVER_DEAL     = IManagementProposals.revokeMP.selector;           // Default quorum
    bytes4 public constant DEAL_MESSAGE     = IManagementProposals.revokeMP.selector;           // Default quorum

    bytes4 public constant ADD_MODULE       = IManagementProposals.addModuleFactory.selector;          // High quorum

    // If the legal wrapper is set, executing this proposal will require explicit legal wrapper authorization.
    // Authorization of the legal wrapper is indicated by legal wrapper himself executing the proposal.
    bytes4 public constant REMOVE_MODULE    = IManagementProposals.removeModuleFactory.selector;       // High quorum
}
