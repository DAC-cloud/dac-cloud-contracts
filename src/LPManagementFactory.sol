// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LPManagementProposal.sol";
import "./Interfaces.sol";

contract LPManagementFactory {
    function deployLPManagement(
        uint256 id,
        LPMParams calldata params,
        address dac,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        LPMParams memory proposalParams = params;
        
        bool highQuorum = (
            params.typ == LPManagementType.MintLP ||
            params.typ == LPManagementType.UpdateVotingConfig ||
            params.typ == LPManagementType.UpdateLegalWrapper || 
            params.typ == LPManagementType.Dividend ||
            params.typ == LPManagementType.AddTrustedEvaluatorFactory ||
            params.typ == LPManagementType.RemoveTrustedEvaluatorFactory
        );

        bool blockingQuorum = (
            params.typ == LPManagementType.ApproveOffchainAction ||
            params.typ == LPManagementType.RevokeMP ||
            params.typ == LPManagementType.CapitalCall ||
            params.typ == LPManagementType.ApproveDeal ||
            params.typ == LPManagementType.ApproveTranche
        );

        LPManagementProposal prop = new LPManagementProposal(
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