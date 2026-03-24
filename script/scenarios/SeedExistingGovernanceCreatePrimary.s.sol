// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingDACSeed, ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceCreatePrimary is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        ExistingDACSeed memory existing;
        (existing, seed) = _initExistingGovernanceSeed(config);

        vm.startBroadcast(founderKey());
        seed.primaryProposalId = _createDACProposal(seed.dac, _mintAgentProposal(seed.recipient, config.agentMintAmount));
        seed.primaryProposal = DACCell(seed.dac).getProposalVoting(seed.primaryProposalId);
        seed.primarySnapshotBlock = _proposal(seed.dac, seed.primaryProposalId).primarySnapshotBlock();
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance primary proposal created");
        console2.log("  existing DAC label:", existing.label);
        console2.log("  proposalId:", seed.primaryProposalId);
        console2.log("  proposal:", seed.primaryProposal);
        console2.log("  snapshotBlock:", seed.primarySnapshotBlock);
        console2.log("  manifest:", manifestPath);
    }
}
