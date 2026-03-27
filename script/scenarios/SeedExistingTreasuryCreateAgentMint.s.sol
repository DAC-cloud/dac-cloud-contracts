// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {ExistingDACSeed, ExistingTreasuryFlowSeed, ExistingTreasuryFlowSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";

contract SeedExistingTreasuryCreateAgentMint is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        (ProtocolDeployment memory protocol, ExistingDACSeed memory existing, ExistingTreasuryFlowSeed memory flowSeed) =
            _initExistingTreasurySeed(config);
        protocol;
        existing;
        seed = flowSeed;

        vm.startBroadcast(founderKey());
        seed.mintAgentProposalId = _createMintAgentProposal(seed.dac, seed.agent, config.agentMintAmount);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow agent mint proposal created");
        console2.log("  label:", seed.label);
        console2.log("  mintAgentProposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
