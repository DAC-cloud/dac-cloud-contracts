// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {BasicDACSeed, ChildDACFlowSeed, ChildDACFlowSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACCreateAgentMint is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        (ProtocolDeployment memory protocol, BasicDACSeed memory basic, ChildDACFlowSeed memory flowSeed) =
            _initChildDACSeed(config);
        protocol;
        basic;
        seed = flowSeed;

        vm.startBroadcast(founderKey());
        seed.mintAgentProposalId = _createMintAgentProposal(seed.dac, seed.agent, config.agentMintAmount);
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC flow agent mint proposal created");
        console2.log("  label:", seed.label);
        console2.log("  mintAgentProposalId:", seed.mintAgentProposalId);
        console2.log("  manifest:", manifestPath);
    }
}

