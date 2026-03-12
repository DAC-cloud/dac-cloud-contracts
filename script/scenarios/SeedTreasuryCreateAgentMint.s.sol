// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {BasicDACSeed, ProtocolDeployment, TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";

contract SeedTreasuryCreateAgentMint is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        (ProtocolDeployment memory protocol, BasicDACSeed memory basic, TreasuryFlowSeed memory flowSeed) =
            _initTreasurySeed(config);
        protocol;
        basic;
        seed = flowSeed;

        vm.startBroadcast(founderKey());
        seed.mintAgentProposalId = _createMintAgentProposal(seed.dac, seed.agent, config.agentMintAmount);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow agent mint proposal created");
        console2.log("  label:", seed.label);
        console2.log("  mintAgentProposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
