// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernancePublishPrimary is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);
        if (seed.primaryProposalId == 0 || seed.primaryProposal == address(0)) revert PrimaryProposalNotPrepared();

        seed.primarySnapshotBlock = _proposal(seed.dac, seed.primaryProposalId).primarySnapshotBlock();
        seed.primaryUnderlyingAmount = _resolveMerkleAmount(seed, config);
        seed.primaryMerkleRoot = _singleLeafRoot(config.merkleIndex, seed.founder, seed.primaryUnderlyingAmount);

        vm.startBroadcast(broadcasterKey());
        _publishDACOracleSnapshot(
            seed.governanceOracle,
            seed.dac,
            seed.primaryProposalId,
            seed.primarySnapshotBlock,
            seed.primaryMerkleRoot,
            seed.primaryUnderlyingAmount
        );
        _activatePrimaryDACProposal(seed.dac, seed.primaryProposalId);
        seed.primaryPublished = true;
        seed.primaryActivated = true;
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance primary snapshot published");
        console2.log("  proposalId:", seed.primaryProposalId);
        console2.log("  merkleRoot:");
        console2.logBytes32(seed.primaryMerkleRoot);
        console2.log("  underlying voting power:", seed.primaryUnderlyingAmount);
        console2.log("  manifest:", manifestPath);
    }
}
