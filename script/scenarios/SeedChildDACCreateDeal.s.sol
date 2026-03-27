// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig, ProtocolDeployment} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACCreateDeal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        ProtocolDeployment memory protocol = loadProtocolManifest();
        seed = loadChildDACFlowManifest(config.label);

        if (!seed.agentMinted) revert AgentMintNotExecuted();
        if (AgentToken(seed.agentToken).balanceOf(seed.agent) < config.stakeAmount) revert AgentMintNotExecuted();

        vm.startBroadcast(agentKey());
        Vm.Log[] memory logs = _createChildDACDeal(seed, protocol, config);
        vm.stopBroadcast();

        seed.dacProposalId = _findDealCreatedProposalId(logs);
        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC deal created");
        console2.log("  label:", seed.label);
        console2.log("  dealId:", seed.dealId);
        console2.log("  deal:", seed.deal);
        console2.log("  dealCell:", seed.dealCell);
        console2.log("  dacProposalId:", seed.dacProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
