// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakedMPProposal.sol";
import "./Interfaces.sol";

contract StakedMPProposalFactory {
    function deployProposal(
        uint256 id,
        StakedMPParams calldata proposal,
        address deal,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        StakedMPParams memory proposalParams = proposal;
        
        bool highQuorum = (
            proposal.typ == StakedMPManagementType.UpdateVotingConfig ||
            proposal.typ == StakedMPManagementType.RequestTranche ||
            proposal.typ == StakedMPManagementType.AddStake ||
            proposal.typ == StakedMPManagementType.ToggleEarlyReturns ||
            proposal.typ == StakedMPManagementType.ToggleWhitelist
        );

        bool blockingQuorum = (
            proposal.typ == StakedMPManagementType.ChildLPProposalVoting ||
            proposal.typ == StakedMPManagementType.ApprovePermit2Spend
        );

        StakedMPProposal prop = new StakedMPProposal(
            id, 
            proposalParams, 
            deal,
            votingConfig.duration,
            highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
            blockingQuorum ? votingConfig.blockingPercent : 0
        );

        return address(prop);
    }
}