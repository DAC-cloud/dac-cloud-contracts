// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";
import {ExistingTreasuryFlowSeed, ExistingTreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedExistingTreasuryPublishApproveDeal is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        seed = loadExistingTreasuryFlowManifest(config.label);

        if (seed.dacProposalId == 0) revert ExistingTreasuryFlowNotPrepared();

        seed.approveDealSnapshotBlock = _proposal(seed.dac, seed.dacProposalId).primarySnapshotBlock();
        seed.approveDealUnderlyingAmount = _resolveMerkleAmountForExistingTreasury(seed, config);
        seed.approveDealMerkleRoot = _singleLeafRoot(config.merkleIndex, seed.founder, seed.approveDealUnderlyingAmount);

        vm.startBroadcast(founderKey());
        _publishDACOracleSnapshot(
            seed.governanceOracle,
            seed.dacProposalId,
            seed.approveDealSnapshotBlock,
            seed.approveDealMerkleRoot,
            seed.approveDealUnderlyingAmount
        );
        _activatePrimaryDACProposal(seed.dac, seed.dacProposalId);
        vm.stopBroadcast();

        seed.dealApprovalPublished = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow deal approval published");
        console2.log("  label:", seed.label);
        console2.log("  proposalId:", seed.dacProposalId);
        console2.log("  snapshotBlock:", seed.approveDealSnapshotBlock);
        console2.log("  manifest:", manifestPath);
    }
}
