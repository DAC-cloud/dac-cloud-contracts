// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";
import {ExistingTreasuryFlowSeed, ExistingTreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedExistingTreasuryPublishAgentMint is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        seed = loadExistingTreasuryFlowManifest(config.label);

        if (seed.mintAgentProposalId == 0) revert ExistingTreasuryFlowNotPrepared();

        seed.mintAgentSnapshotBlock = _proposal(seed.dac, seed.mintAgentProposalId).primarySnapshotBlock();
        seed.mintAgentUnderlyingAmount = _resolveMerkleAmountForExistingTreasury(seed, config);
        seed.mintAgentMerkleRoot = _singleLeafRoot(config.merkleIndex, seed.founder, seed.mintAgentUnderlyingAmount);

        vm.startBroadcast(founderKey());
        _publishDACOracleSnapshot(
            seed.governanceOracle,
            seed.mintAgentProposalId,
            seed.mintAgentSnapshotBlock,
            seed.mintAgentMerkleRoot,
            seed.mintAgentUnderlyingAmount
        );
        _activatePrimaryDACProposal(seed.dac, seed.mintAgentProposalId);
        vm.stopBroadcast();

        seed.mintAgentPublished = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow agent mint published");
        console2.log("  label:", seed.label);
        console2.log("  proposalId:", seed.mintAgentProposalId);
        console2.log("  snapshotBlock:", seed.mintAgentSnapshotBlock);
        console2.log("  manifest:", manifestPath);
    }
}
