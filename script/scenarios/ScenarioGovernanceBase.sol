// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ManifestIO} from "../common/ManifestIO.sol";
import {IVoting} from "../../src/interfaces/IVoting.sol";
import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {Deal} from "../../src/kernel/Deal.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {IBasicGovernanceOracle} from "../../src/interfaces/IBasicGovernanceOracle.sol";
import {HybridDACManagementProposal} from "../../src/kernel/governance/HybridDACManagementProposal.sol";

abstract contract ScenarioGovernanceBase is ManifestIO {
    function _createDACProposal(address dac, ProposalParams memory params) internal returns (uint256 proposalId) {
        proposalId = DACCell(dac).createManagementProposal(params);
    }

    function _voteDACProposal(address dac, uint256 proposalId, bool support) internal {
        IVoting(DACCell(dac).getProposalVoting(proposalId)).vote(support);
    }

    function _executeDACProposal(address dac, uint256 proposalId) internal {
        DACCell(dac).executeDACProposal(proposalId);
    }

    function _voteAndExecuteDACProposal(address dac, uint256 proposalId, bool support) internal {
        _voteDACProposal(dac, proposalId, support);
        _executeDACProposal(dac, proposalId);
    }

    function _publishDACOracleSnapshot(
        address governanceOracle,
        address dac,
        uint256 proposalId,
        uint256 snapshotBlock,
        bytes32 merkleRoot,
        uint256 totalUnderlyingVotingPower
    ) internal {
        IBasicGovernanceOracle(governanceOracle).publishSnapshot(
            dac, proposalId, snapshotBlock, merkleRoot, totalUnderlyingVotingPower
        );
    }

    function _activatePrimaryDACProposal(address dac, uint256 proposalId) internal {
        HybridDACManagementProposal(DACCell(dac).getProposalVoting(proposalId)).activatePrimaryVoting();
    }

    function _voteDACProposalMerkle(
        address dac,
        uint256 proposalId,
        bool support,
        uint256 index,
        uint256 amount,
        bytes32[] memory proof
    ) internal {
        HybridDACManagementProposal(DACCell(dac).getProposalVoting(proposalId)).voteMerkle(
            support, index, amount, proof
        );
    }

    function _beginFallbackWarmup(address dac, uint256 proposalId) internal {
        HybridDACManagementProposal(DACCell(dac).getProposalVoting(proposalId)).beginFallbackWarmup();
    }

    function _activateFallbackDACProposal(address dac, uint256 proposalId) internal {
        HybridDACManagementProposal(DACCell(dac).getProposalVoting(proposalId)).activateFallbackVoting();
    }

    function _createMintAgentProposal(address dac, address agent, uint256 amount) internal returns (uint256 proposalId) {
        proposalId = _createDACProposal(
            dac,
            ProposalParams({
                typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                target: agent,
                i: bytes32(amount),
                data: bytes("")
            })
        );
    }

    function _createDealProposal(address deal, ProposalParams memory params) internal returns (uint256 proposalId) {
        proposalId = Deal(deal).createStakedAgentProposal(params);
    }

    function _voteDealProposal(address deal, uint256 proposalId, bool support) internal {
        IVoting(Deal(deal).getProposal(proposalId)).vote(support);
    }

    function _executeDealProposal(address deal, uint256 proposalId) internal {
        Deal(deal).executeStakedAgentProposal(proposalId);
    }

    function _voteAndExecuteDealProposal(address deal, uint256 proposalId, bool support) internal {
        _voteDealProposal(deal, proposalId, support);
        _executeDealProposal(deal, proposalId);
    }
}
