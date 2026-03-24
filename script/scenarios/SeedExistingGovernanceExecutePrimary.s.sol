// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingGovernanceFlowSeed, ExistingGovernanceFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ExistingGovernanceFlowBase} from "./ExistingGovernanceFlowBase.sol";

contract SeedExistingGovernanceExecutePrimary is ExistingGovernanceFlowBase {
    function run() external returns (ExistingGovernanceFlowSeed memory seed) {
        ExistingGovernanceFlowSeedConfig memory config = loadExistingGovernanceFlowSeedConfig();
        seed = loadExistingGovernanceFlowManifest(config.label);
        if (!seed.primaryVoted) revert PrimaryProposalNotPrepared();

        vm.startBroadcast(broadcasterKey());
        _executeDACProposal(seed.dac, seed.primaryProposalId);
        seed.primaryExecuted = true;
        seed.blockNumber = block.number;
        vm.stopBroadcast();

        string memory manifestPath = writeExistingGovernanceFlowManifest(seed);

        console2.log("Existing governance primary proposal executed");
        console2.log("  proposalId:", seed.primaryProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
