// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceVotePrimary is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);
        if (!seed.primaryActivated) revert PrimaryProposalNotPrepared();

        bytes32[] memory proof = new bytes32[](0);

        vm.startBroadcast(founderKey());
        _voteDACProposal(seed.dac, seed.primaryProposalId, true);
        _voteDACProposalMerkle(
            seed.dac,
            seed.primaryProposalId,
            true,
            config.merkleIndex,
            seed.primaryUnderlyingAmount,
            proof
        );
        seed.primaryVoted = true;
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance primary votes cast");
        console2.log("  proposalId:", seed.primaryProposalId);
        console2.log("  merkle index:", config.merkleIndex);
        console2.log("  manifest:", manifestPath);
    }
}
