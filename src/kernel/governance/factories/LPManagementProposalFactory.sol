// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../LPManagementProposals.sol";
import "../LPManagementProposal.sol";

contract LPManagementProposalFactory {
    function deployManagementProposal(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        ProposalParams memory proposalParams = params;
        
        bool highQuorum = (
            params.typ == LPManagementProposalType.MINT_LP_TOKENS ||
            params.typ == LPManagementProposalType.UPDATE_VOTING_CONFIG ||
            params.typ == LPManagementProposalType.UPDATE_LEGAL_WRAPPER || 
            params.typ == LPManagementProposalType.DIVIDEND_PAYOUT ||
            params.typ == LPManagementProposalType.ADD_DEAL_FACTORY ||
            params.typ == LPManagementProposalType.REMOVE_DEAL_FACTORY ||
            params.typ == LPManagementProposalType.ADD_EVALUATOR_FACTORY ||
            params.typ == LPManagementProposalType.REMOVE_EVALUATOR_FACTORY
        );

        bool blockingQuorum = (
            params.typ == LPManagementProposalType.APPROVE_OFFCHAIN_ACTION ||
            params.typ == LPManagementProposalType.REVOKE_MP_TOKENS ||
            params.typ == LPManagementProposalType.CAPITAL_CALL ||
            params.typ == LPManagementProposalType.APPROVE_DEAL ||
            params.typ == LPManagementProposalType.APPROVE_TRANCHE
        );

        Proposal prop = new LPManagementProposal(
            id, 
            dac, 
            token, 
            proposalParams, 
            votingConfig.duration,
            highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
            blockingQuorum ? votingConfig.blockingPercent : 0
        );

        return address(prop);
    }
}