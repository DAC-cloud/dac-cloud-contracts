// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";
import {IDACManagementFactory} from "../../interfaces/IDACManagementFactory.sol";
import {DACManagementProposalType} from "../DACManagementProposals.sol";
import {DACManagementProposal} from "../DACManagementProposal.sol";
import {MathLib} from "../../libraries/MathLib.sol";

contract DACManagementProposalFactory is IDACManagementFactory {

    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new DACManagementProposal());
    }

    function deployProposal(
        uint256 id,
        ProposalParams memory proposalParams,
        address dac,
        address token,
        uint256 totalVotingSupply,
        VotingConfig memory votingConfig
    ) external returns (address proposalAddress) {
        uint256 quorum;
        uint256 blockingQuorum;

        if (
            proposalParams.typ == DACManagementProposalType.MINT_MAIN_TOKENS ||
            proposalParams.typ == DACManagementProposalType.UPDATE_GOVERNANCE_STRATEGY ||
            proposalParams.typ == DACManagementProposalType.UPDATE_DEAL_CREATION_CONFIG ||
            proposalParams.typ == DACManagementProposalType.UPDATE_GOVERNANCE_ORACLE ||
            proposalParams.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG ||
            proposalParams.typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER || 
            proposalParams.typ == DACManagementProposalType.DIVIDEND_PAYOUT ||
            proposalParams.typ == DACManagementProposalType.ADD_MODULE ||
            proposalParams.typ == DACManagementProposalType.REMOVE_MODULE ||
            proposalParams.typ == DACManagementProposalType.TOGGLE_DIVIDENDS
        ) {
            quorum = MathLib.mul(totalVotingSupply, votingConfig.highQuorumPercent);
        }
        else {
            quorum = MathLib.mul(totalVotingSupply, votingConfig.quorumPercent);
        }

        if (
            proposalParams.typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION ||
            proposalParams.typ == DACManagementProposalType.REVOKE_AGENT_TOKENS ||
            proposalParams.typ == DACManagementProposalType.CAPITAL_CALL ||
            proposalParams.typ == DACManagementProposalType.APPROVE_DEAL ||
            proposalParams.typ == DACManagementProposalType.APPROVE_TRANCHE ||
            proposalParams.typ == DACManagementProposalType.ADD_EVALUATOR ||
            proposalParams.typ == DACManagementProposalType.BURN_MAIN_TOKENS ||
            proposalParams.typ == DACManagementProposalType.DELEGATE_VOTE_RIGHTS
        ) {
            blockingQuorum = MathLib.mul(totalVotingSupply, votingConfig.blockingPercent);
        }

        bytes memory initData = abi.encodeWithSelector(
            DACManagementProposal.initialize.selector,
            id, 
            dac, 
            token, 
            proposalParams, 
            votingConfig.duration,
            votingConfig.executionValidityDuration,
            totalVotingSupply,
            quorum,
            blockingQuorum
        );

        proposalAddress = address(new UUPSProxy(address(referenceImpl), initData));
    }
}
