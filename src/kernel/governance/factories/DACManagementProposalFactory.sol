// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";
import {IDACManagementFactory} from "../../interfaces/IDACManagementFactory.sol";
import {DACManagementProposalType} from "../DACManagementProposals.sol";
import {DACManagementProposal} from "../DACManagementProposal.sol";

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
            proposalParams.typ == DACManagementProposalType.UPDATE_VOTING_CONFIG ||
            proposalParams.typ == DACManagementProposalType.UPDATE_LEGAL_WRAPPER || 
            proposalParams.typ == DACManagementProposalType.DIVIDEND_PAYOUT ||
            proposalParams.typ == DACManagementProposalType.ADD_MODULE ||
            proposalParams.typ == DACManagementProposalType.REMOVE_MODULE ||
            proposalParams.typ == DACManagementProposalType.TOGGLE_DIVIDENDS
        ) {
            quorum = totalVotingSupply * votingConfig.highQuorumPercent / 100;
        }
        else {
            quorum = totalVotingSupply * votingConfig.quorumPercent / 100;
        }

        if (
            proposalParams.typ == DACManagementProposalType.APPROVE_OFFCHAIN_ACTION ||
            proposalParams.typ == DACManagementProposalType.REVOKE_AGENT_TOKENS ||
            proposalParams.typ == DACManagementProposalType.CAPITAL_CALL ||
            proposalParams.typ == DACManagementProposalType.APPROVE_DEAL ||
            proposalParams.typ == DACManagementProposalType.APPROVE_TRANCHE ||
            proposalParams.typ == DACManagementProposalType.ADD_EVALUATOR ||
            proposalParams.typ == DACManagementProposalType.BURN_MAIN_TOKENS
        ) {
            blockingQuorum = totalVotingSupply * votingConfig.blockingPercent / 100;
        }

        bytes memory initData = abi.encodeWithSelector(
            DACManagementProposal.initialize.selector,
            id, 
            dac, 
            token, 
            proposalParams, 
            votingConfig.duration,
            totalVotingSupply,
            quorum,
            blockingQuorum
        );

        proposalAddress = address(new UUPSProxy(address(referenceImpl), initData));
    }
}