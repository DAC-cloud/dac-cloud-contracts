// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../../interfaces/Structs.sol";
import "../CoreDealManagementProposals.sol";
import "../../../../kernel/governance/DealManagementProposal.sol";
import "../../../../kernel/governance/factories/DealManagementProposalFactory.sol";

contract CoreManagementProposalFactory is DealManagementProposalFactory {
    function moduleManagementProposalQuorum(
        uint256,
        ProposalParams calldata params,
        address,
        address,
        address,
        VotingConfig calldata
    ) internal override pure returns (
        bool ok, 
        bool highQuorum, 
        bool allowBlocking
    ) {
        ok = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.CREATE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL || 
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND || 
            params.typ == CoreDealManagementType.ASSIGN_CLAIMER ||
            params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC
        );

        highQuorum = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND
        );

        allowBlocking = (
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL || 
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND
        );
    }
}