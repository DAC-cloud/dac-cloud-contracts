// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";
import {IDealManagementProposalFactory} from "../../interfaces/IDealManagementProposalFactory.sol";
import {AbstractDealManagementType} from "../AbstractDealManagementProposals.sol";
import {DealManagementProposal} from "../DealManagementProposal.sol";
import {MathLib} from "../../libraries/MathLib.sol";

abstract contract DealManagementProposalFactory is IDealManagementProposalFactory {
    error ProposalNotSupported();

    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new DealManagementProposal());
    }

    struct QuorumConfig {
        bool allowed;
        bool high;
        bool veto;
        bool blocking;
    }

    function deployProposal(
        uint256 id,
        ProposalParams memory params,
        address dac,
        address deal,
        address token,
        bool vetoEnabled,
        VotingConfig memory votingConfig
    ) external returns (address proposalAddress) {
        uint256 quorum;
        uint256 blockingQuorum;
        bool challengeable;

        uint256 totalSupply = IERC20(token).totalSupply();

        if (
            params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
            params.typ == AbstractDealManagementType.REQUEST_TRANCHE ||
            params.typ == AbstractDealManagementType.ADD_STAKE || 
            params.typ == AbstractDealManagementType.PERMIT_UNSTAKE ||
            params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
            params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
            params.typ == AbstractDealManagementType.ENABLE_VETO_RIGHT ||
            params.typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD
        ) {
            if (
                params.typ == AbstractDealManagementType.UPDATE_VOTING_CONFIG ||
                params.typ == AbstractDealManagementType.ENABLE_VETO_RIGHT ||
                params.typ == AbstractDealManagementType.ADD_STAKE || 
                params.typ == AbstractDealManagementType.PERMIT_UNSTAKE ||
                params.typ == AbstractDealManagementType.TOGGLE_WHITELIST ||
                params.typ == AbstractDealManagementType.TOGGLE_EARLY_RETURNS ||
                params.typ == AbstractDealManagementType.PERMIT_EVALUATOR_ADD
            ) {
                quorum = MathLib.mul(totalSupply, votingConfig.highQuorumPercent);

                if (vetoEnabled || params.typ == AbstractDealManagementType.PERMIT_UNSTAKE) {
                    challengeable = true;
                }
            }
            else {
                quorum = MathLib.mul(totalSupply, votingConfig.quorumPercent);
            }

            if (
                params.typ == AbstractDealManagementType.REQUEST_TRANCHE
            ) {
                blockingQuorum = MathLib.mul(totalSupply, votingConfig.blockingPercent);

                if (vetoEnabled) {
                    challengeable = true;
                }
            }
        }

        // Module proposal
        else {
            QuorumConfig memory quorumConfig = moduleManagementProposalQuorum(
                id,
                params,
                dac,
                deal,
                token,
                votingConfig
            );

            // Module controls proposal configuration for all deals of the Module
            
            // Module-specific factory is allowed to examine deal (and/or dac) state 
            //  to enforce it's own quorum rules
            
            require(quorumConfig.allowed, ProposalNotSupported());

            if (quorumConfig.high) {
                quorum = MathLib.mul(totalSupply, votingConfig.highQuorumPercent);
            }
            else {
                quorum = MathLib.mul(totalSupply, votingConfig.quorumPercent);
            }

            if (quorumConfig.blocking) {
                blockingQuorum = MathLib.mul(totalSupply, votingConfig.blockingPercent);
            }
            
            if (vetoEnabled) {
                if (quorumConfig.high || quorumConfig.blocking || quorumConfig.veto) {
                    challengeable = true;
                }
            }
        }

        bytes memory initData = abi.encodeWithSelector(
            DealManagementProposal.initialize.selector,
            id,
            abi.encode(dac, deal, token, challengeable),
            abi.encode(votingConfig.duration, votingConfig.executionValidityDuration, totalSupply, quorum, blockingQuorum),
            params
        );

        proposalAddress = address(new UUPSProxy(address(referenceImpl), initData));
    }

    function moduleManagementProposalQuorum(
        uint256 id,
        ProposalParams memory params,
        address dac,
        address deal,
        address token,
        VotingConfig memory votingConfig
    ) internal virtual returns (
        QuorumConfig memory
    ) {
        // default is - not `ok`, so any module need to override this method
        // to fill quorum configuration for custom proposal types
    }
}
