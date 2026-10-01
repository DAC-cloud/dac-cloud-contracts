// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICoreDealManagementProposals {
    // DAC deal
    function reinvestProfits() external pure returns (bytes4);
    function createDACManagementProposal() external pure returns (bytes4);
    function voteDACManagementProposal() external pure returns (bytes4);
    function returnProfits() external pure returns (bytes4);
    function approveVotingVenueVersion() external pure returns (bytes4);
    function externalVoteSign() external pure returns (bytes4);

    // Treasury deal
    function directSpend() external pure returns (bytes4);
    function approvePermit2Spend() external pure returns (bytes4);
    function approveAgentSpend() external pure returns (bytes4);
    function assignClaimer() external pure returns (bytes4);
    function revokeAgent() external pure returns (bytes4);
    function returnCapitalToDAC() external pure returns (bytes4);
    function delegateVotingPower() external pure returns (bytes4);

    // Agent deal (DAC acts as an agent inside another, host DAC)
    function hostStake() external pure returns (bytes4);
    function hostApproveStake() external pure returns (bytes4);
    function hostCreateDeal() external pure returns (bytes4);
    function hostCreateProposal() external pure returns (bytes4);
    function hostVote() external pure returns (bytes4);
    function hostClaimReward() external pure returns (bytes4);
    function hostUnstake() external pure returns (bytes4);
    function hostInvite() external pure returns (bytes4);
    function returnAssetToDAC() external pure returns (bytes4);
}

library CoreDealManagementType {
    bytes4 public constant REINVEST_PROFITS              = ICoreDealManagementProposals.reinvestProfits.selector;               // High quorum
    bytes4 public constant CREATE_DAC_PROPOSAL           = ICoreDealManagementProposals.createDACManagementProposal.selector;   // Default quorum
    bytes4 public constant VOTE_DAC_PROPOSAL             = ICoreDealManagementProposals.voteDACManagementProposal.selector;     // Default quorum, blocking allowed
    bytes4 public constant RETURN_PROFITS                = ICoreDealManagementProposals.returnProfits.selector;                 // Default quorum
    bytes4 public constant APPROVE_VOTING_VENUE_VERSION  = ICoreDealManagementProposals.approveVotingVenueVersion.selector;     // High quorum, blocking allowed
    bytes4 public constant EXTERNAL_VOTE_SIGN            = ICoreDealManagementProposals.externalVoteSign.selector;              // Default quorum, blocking allowed

    bytes4 public constant APPROVE_DIRECT_SPEND  = ICoreDealManagementProposals.directSpend.selector;                   // High quorum
    bytes4 public constant APPROVE_PERMIT2_SPEND = ICoreDealManagementProposals.approvePermit2Spend.selector;           // Default quorum, blocking allowed
    bytes4 public constant APPROVE_AGENT_SPEND   = ICoreDealManagementProposals.approveAgentSpend.selector;             // Default quorum, blocking allowed
    bytes4 public constant ASSIGN_CLAIMER        = ICoreDealManagementProposals.assignClaimer.selector;                 // Default quorum
    bytes4 public constant REVOKE_AGENT          = ICoreDealManagementProposals.revokeAgent.selector;                   // Default quorum
    bytes4 public constant RETURN_CAPITAL_TO_DAC = ICoreDealManagementProposals.returnCapitalToDAC.selector;            // Default quorum
    bytes4 public constant DELEGATE_VOTE_RIGHTS  = ICoreDealManagementProposals.delegateVotingPower.selector;           // Default quorum, blocking allowed

    bytes4 public constant HOST_STAKE            = ICoreDealManagementProposals.hostStake.selector;                     // High quorum, veto allowed
    bytes4 public constant HOST_APPROVE_STAKE    = ICoreDealManagementProposals.hostApproveStake.selector;             // High quorum, veto allowed
    bytes4 public constant HOST_CREATE_DEAL      = ICoreDealManagementProposals.hostCreateDeal.selector;               // High quorum, veto allowed
    bytes4 public constant HOST_CREATE_PROPOSAL  = ICoreDealManagementProposals.hostCreateProposal.selector;           // Default quorum, blocking allowed
    bytes4 public constant HOST_VOTE             = ICoreDealManagementProposals.hostVote.selector;                     // Default quorum, blocking allowed
    bytes4 public constant HOST_CLAIM_REWARD     = ICoreDealManagementProposals.hostClaimReward.selector;              // Default quorum
    bytes4 public constant HOST_UNSTAKE          = ICoreDealManagementProposals.hostUnstake.selector;                  // Default quorum, blocking allowed
    bytes4 public constant HOST_INVITE           = ICoreDealManagementProposals.hostInvite.selector;                   // Default quorum
    bytes4 public constant RETURN_ASSET_TO_DAC   = ICoreDealManagementProposals.returnAssetToDAC.selector;             // Default quorum
}
