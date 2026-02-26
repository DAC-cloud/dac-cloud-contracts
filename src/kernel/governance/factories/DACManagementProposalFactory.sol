// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../DACManagementProposals.sol";
import "../DACManagementProposal.sol";

contract DACManagementProposalFactory {
    function deployManagementProposal(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        ProposalParams memory proposalParams = params;
        
        bool highQuorum = (
            params.typ == DACManagementProposalType.MINT_MAIN_TOKENS ||
            params.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG ||
            params.typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER || 
            params.typ == DACManagementProposalType.DIVIDEND_PAYOUT ||
            params.typ == DACManagementProposalType.ADD_MODULE ||
            params.typ == DACManagementProposalType.REMOVE_MODULE ||
            params.typ == DACManagementProposalType.TOGGLE_DIVIDENDS
        );

        bool blockingQuorum = (
            params.typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION ||
            params.typ == DACManagementProposalType.REVOKE_AGENT_TOKENS ||
            params.typ == DACManagementProposalType.CAPITAL_CALL ||
            params.typ == DACManagementProposalType.APPROVE_DEAL ||
            params.typ == DACManagementProposalType.APPROVE_TRANCHE ||
            params.typ == DACManagementProposalType.BURN_MAIN_TOKENS
        );

        //todo: recalculate quorum from percent to balance

        Proposal prop = new DACManagementProposal(
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