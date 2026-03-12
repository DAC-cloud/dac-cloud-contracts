// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedTreasuryExecuteAgentMint is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        seed = loadTreasuryFlowManifest(config.label);

        if (seed.mintAgentProposalId == 0) revert TreasuryFlowNotPrepared();

        vm.startBroadcast(founderKey());
        _voteAndExecuteDACProposal(seed.dac, seed.mintAgentProposalId, true);
        vm.stopBroadcast();

        seed.agentMinted = true;
        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow agent mint executed");
        console2.log("  label:", seed.label);
        console2.log("  mintAgentProposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
