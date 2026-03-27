// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";
import {ExistingTreasuryFlowSeed, ExistingTreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedExistingTreasuryExecuteAgentMint is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        seed = loadExistingTreasuryFlowManifest(config.label);

        if (!seed.mintAgentPublished) revert ExistingTreasuryFlowNotPrepared();

        bytes32[] memory proof = new bytes32[](0);

        vm.startBroadcast(founderKey());
        _voteDACProposal(seed.dac, seed.mintAgentProposalId, true);
        _voteDACProposalMerkle(
            seed.dac, seed.mintAgentProposalId, true, config.merkleIndex, seed.mintAgentUnderlyingAmount, proof
        );
        _executeDACProposal(seed.dac, seed.mintAgentProposalId);
        vm.stopBroadcast();

        seed.agentMinted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow agent mint executed");
        console2.log("  label:", seed.label);
        console2.log("  proposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
