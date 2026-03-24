// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceExecuteFallback is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);
        if (!seed.fallbackVoted) revert FallbackProposalNotPrepared();

        vm.startBroadcast(broadcasterKey());
        _executeDACProposal(seed.dac, seed.fallbackProposalId);
        seed.fallbackExecuted = true;
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance fallback proposal executed");
        console2.log("  proposalId:", seed.fallbackProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
