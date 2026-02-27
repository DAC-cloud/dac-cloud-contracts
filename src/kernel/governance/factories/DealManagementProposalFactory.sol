// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {AbstractDealManagementType} from "../AbstractDealManagementProposals.sol";
import {DealManagementProposal} from "../DealManagementProposal.sol";

abstract contract DealManagementProposalFactory {
    function deployManagementProposal(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address deal,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        ProposalParams memory proposalParams = params;
        
        bool isAbstract = (
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE || 
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS
        );

        if (isAbstract) {
            bool highQuorum = (
                params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
                params.typ == AbstractDealManagementType.ADD_STAKE || 
                params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
                params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS
            );

            //todo: recalculate quorum from percent to balance

            DealManagementProposal prop = new DealManagementProposal(
                id, 
                dac,
                deal,
                token, 
                proposalParams, 
                votingConfig.duration,
                highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
                0
            );

            return address(prop);
        }

        // Module proposal
        else {
            (bool ok, bool highQuorum, bool blockingQuorum) = moduleManagementProposalQuorum(
                id,
                params,
                dac,
                deal,
                token,
                votingConfig
            );

            require(!ok, "Proposal not supported");

            //todo: recalculate quorum from percent to balance

            DealManagementProposal prop = new DealManagementProposal(
                id, 
                dac,
                deal,
                token, 
                proposalParams, 
                votingConfig.duration,
                highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
                blockingQuorum ? votingConfig.blockingPercent : 0
            );

            return address(prop);
        }
    }

    function moduleManagementProposalQuorum(
        uint256 id,
        ProposalParams calldata params,
        address dac,
        address deal,
        address token,
        VotingConfig calldata votingConfig
    ) internal virtual returns (
        bool ok, 
        bool highQuorum, 
        bool allowBlocking
    ) {
        // default is - not `ok`, so any module need to override this method
        // to fill quorum configuration for custom proposal types
    }
}