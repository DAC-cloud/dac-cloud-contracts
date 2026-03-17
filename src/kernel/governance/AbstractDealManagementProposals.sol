// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAbstractDealManagementProposals {
    function updateVotingConfig() external pure returns (bytes4);

    function requestTranche() external pure returns (bytes4);

    function addStake() external pure returns (bytes4);
    function permitUnstake() external pure returns (bytes4);

    function enableVetoRight() external pure returns (bytes4);

    function toggleWhitelist() external pure returns (bytes4);

    function toggleEarlyReturns() external pure returns (bytes4);

    function permitEvaluatorAdd() external pure returns (bytes4);
}

library AbstractDealManagementType {
    bytes4 public constant UPDATE_VOTING_CONFIG = IAbstractDealManagementProposals.updateVotingConfig.selector; // High quorum
    
    bytes4 public constant REQUEST_TRANCHE      = IAbstractDealManagementProposals.requestTranche.selector;     // Default quorum, blocking allowed
    
    bytes4 public constant ADD_STAKE            = IAbstractDealManagementProposals.addStake.selector;           // High quorum
    bytes4 public constant PERMIT_UNSTAKE       = IAbstractDealManagementProposals.permitUnstake.selector;      // High quorum, always allows veto

    bytes4 public constant TOGGLE_WHITELIST     = IAbstractDealManagementProposals.toggleWhitelist.selector;    // High quorum
    
    bytes4 public constant ENABLE_VETO_RIGHT    = IAbstractDealManagementProposals.enableVetoRight.selector;    // High quorum

    bytes4 public constant TOGGLE_EARLY_RETURNS = IAbstractDealManagementProposals.toggleEarlyReturns.selector; // High quorum

    bytes4 public constant PERMIT_EVALUATOR_ADD = IAbstractDealManagementProposals.permitEvaluatorAdd.selector; // High quorum
}
