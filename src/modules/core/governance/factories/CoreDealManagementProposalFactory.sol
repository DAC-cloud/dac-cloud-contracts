// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "../../../../interfaces/Structs.sol";
import {CoreDealManagementType} from "../CoreDealManagementProposals.sol";
import {DealManagementProposalFactory} from "../../../../kernel/governance/factories/DealManagementProposalFactory.sol";

contract CoreManagementProposalFactory is DealManagementProposalFactory {
    function moduleManagementProposalQuorum(
        uint256,
        ProposalParams memory params,
        address,
        address,
        address,
        VotingConfig memory
    ) internal override pure returns (
        QuorumConfig memory quorum
    ) {
        // Here we are not differentiating by deal types, as we should, but instead
        //  mismatched proposals would be reverted on execution if ever accepted.

        // While this can be in future fixed, since modules are upgradeable, we advice
        //  module developers to differentiate properly there, with maybe a registry of
        //  all deals launched with the module, to know deal type

        quorum.allowed = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.CREATE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL || 
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND || 
            params.typ == CoreDealManagementType.ASSIGN_CLAIMER ||
            params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC
        );

        quorum.high = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND
        );

        quorum.veto = quorum.high;

        quorum.blocking = (
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL || 
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND
        );
    }
}