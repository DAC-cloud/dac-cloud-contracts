// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagementProposals {
    function updateVotingConfig() external pure returns (bytes4);

    function updateLegalWrapper() external pure returns (bytes4);
    function approveOffchainAction() external pure returns (bytes4);

    function mintLP() external pure returns (bytes4);
    function mintMP() external pure returns (bytes4);
    function revokeMP() external pure returns (bytes4);

    function dividendPayout() external pure returns (bytes4);

    function capitalCall() external pure returns (bytes4);

    function addTrustedDealFactory() external pure returns (bytes4);
    function removeTrustedDealFactory() external pure returns (bytes4);

    function addTrustedEvaluatorFactory() external pure returns (bytes4);
    function removeTrustedEvaluatorFactory() external pure returns (bytes4);

    function approveDeal() external pure returns (bytes4);
    function approveTranche() external pure returns (bytes4);

    function recoverDeal() external pure returns (bytes4);

    function passDealMessage() external pure returns (bytes4);
}

library LPManagementProposalType {
    bytes4 public constant UPDATE_VOTING_CONFIG     = IManagementProposals.updateVotingConfig.selector;      // High quorum
    bytes4 public constant UPDATE_LEGAL_WRAPPER     = IManagementProposals.updateLegalWrapper.selector;      // High quorum
    bytes4 public constant APPROVE_OFFCHAIN_ACTION  = IManagementProposals.approveOffchainAction.selector;   // Default quorum, blocking allowed

    bytes4 public constant MINT_LP_TOKENS   = IManagementProposals.mintLP.selector;         // High quorum
    bytes4 public constant MINT_MP_TOKENS   = IManagementProposals.mintMP.selector;         // Default quorum
    bytes4 public constant REVOKE_MP_TOKENS = IManagementProposals.revokeMP.selector;       // Default quorum, blocking allowed

    bytes4 public constant DIVIDEND_PAYOUT  = IManagementProposals.dividendPayout.selector; // High quorum
    bytes4 public constant CAPITAL_CALL     = IManagementProposals.capitalCall.selector;    // Default quorum, blocking allowed

    bytes4 public constant APPROVE_DEAL     = IManagementProposals.mintLP.selector;         // Default quorum, blocking allowed
    bytes4 public constant APPROVE_TRANCHE  = IManagementProposals.mintMP.selector;         // Default quorum, blocking allowed
    bytes4 public constant RECOVER_DEAL     = IManagementProposals.revokeMP.selector;       // Default quorum
    bytes4 public constant DEAL_MESSAGE     = IManagementProposals.revokeMP.selector;       // Default quorum

    bytes4 public constant ADD_DEAL_FACTORY         = IManagementProposals.addTrustedDealFactory.selector;          // High quorum
    bytes4 public constant REMOVE_DEAL_FACTORY      = IManagementProposals.removeTrustedDealFactory.selector;       // High quorum, requires additional authorization by legal wrapper address
    bytes4 public constant ADD_EVALUATOR_FACTORY    = IManagementProposals.addTrustedEvaluatorFactory.selector;     // High quorum
    bytes4 public constant REMOVE_EVALUATOR_FACTORY = IManagementProposals.removeTrustedEvaluatorFactory.selector;  // High quorum
}
