// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExistingDACSeed, ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {DACManagementProposalType} from "../../src/kernel/governance/DACManagementProposals.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {HybridDACManagementProposal} from "../../src/kernel/governance/HybridDACManagementProposal.sol";
import {ScenarioGovernanceBase} from "./ScenarioGovernanceBase.sol";

abstract contract ExistingGovernanceFlowBase is ScenarioGovernanceBase {
    error ExistingGovernanceFlowNotPrepared();
    error PrimaryProposalNotPrepared();
    error FallbackProposalNotPrepared();
    error ZeroUnderlyingVotingPower();

    function _initExistingGovernanceSeed(ExistingGovernanceFlowSeedConfig memory config)
        internal
        view
        returns (ExistingDACSeed memory existing, ExistingGovernanceFlowSeed memory seed)
    {
        existing = loadExistingDACSeedManifest(config.existingDACLabel);

        seed.chainId = block.chainid;
        seed.label = config.label;
        seed.existingDACLabel = config.existingDACLabel;
        seed.founder = vm.addr(founderKey());
        seed.recipient = recipientAddress();
        seed.dac = existing.dac;
        seed.mainToken = existing.mainToken;
        seed.agentToken = existing.agentToken;
        seed.underlyingToken = existing.underlyingToken;
        seed.governanceOracle = existing.governanceOracle;
    }

    function _mintAgentProposal(address recipient, uint256 amount) internal pure returns (ProposalParams memory params) {
        params = ProposalParams({
            typ: DACManagementProposalType.MINT_AGENT_TOKENS,
            target: recipient,
            i: bytes32(amount),
            data: bytes("")
        });
    }

    function _proposal(address dac, uint256 proposalId) internal view returns (HybridDACManagementProposal proposal) {
        proposal = HybridDACManagementProposal(DACCell(dac).getProposalVoting(proposalId));
    }

    function _resolveMerkleAmount(
        ExistingGovernanceFlowSeed memory seed,
        ExistingGovernanceFlowSeedConfig memory config
    ) internal view returns (uint256 amount) {
        amount = config.merkleAmountOverride;
        if (amount == 0) {
            amount = IERC20(seed.underlyingToken).balanceOf(seed.founder);
        }
        if (amount == 0) revert ZeroUnderlyingVotingPower();
    }

    function _singleLeafRoot(uint256 index, address account, uint256 amount) internal pure returns (bytes32 root) {
        root = keccak256(abi.encodePacked(index, account, amount));
    }
}
