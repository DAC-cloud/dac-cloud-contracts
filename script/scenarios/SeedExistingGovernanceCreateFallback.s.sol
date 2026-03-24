// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {DACCell} from "../../src/kernel/DACCell.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceCreateFallback is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);

        vm.startBroadcast(founderKey());
        seed.fallbackProposalId = _createDACProposal(seed.dac, _mintAgentProposal(seed.recipient, config.agentMintAmount));
        seed.fallbackProposal = DACCell(seed.dac).getProposalVoting(seed.fallbackProposalId);
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance fallback proposal created");
        console2.log("  proposalId:", seed.fallbackProposalId);
        console2.log("  proposal:", seed.fallbackProposal);
        console2.log("  manifest:", manifestPath);
    }
}
