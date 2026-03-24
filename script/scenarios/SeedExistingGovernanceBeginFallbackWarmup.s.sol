// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceBeginFallbackWarmup is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);
        if (seed.fallbackProposalId == 0 || seed.fallbackProposal == address(0)) revert FallbackProposalNotPrepared();

        vm.startBroadcast(broadcasterKey());
        _beginFallbackWarmup(seed.dac, seed.fallbackProposalId);
        seed.fallbackWarmupStarted = true;
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance fallback warmup started");
        console2.log("  proposalId:", seed.fallbackProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
