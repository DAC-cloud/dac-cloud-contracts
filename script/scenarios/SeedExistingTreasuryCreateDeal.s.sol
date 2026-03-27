// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";
import {
    ExistingDACSeed,
    ExistingTreasuryFlowSeed,
    ExistingTreasuryFlowSeedConfig,
    ProtocolDeployment
} from "../common/ScriptTypes.sol";
import {ExistingTreasuryFlowBase} from "./ExistingTreasuryFlowBase.sol";

contract SeedExistingTreasuryCreateDeal is ExistingTreasuryFlowBase {
    function run() external returns (ExistingTreasuryFlowSeed memory seed) {
        ExistingTreasuryFlowSeedConfig memory config = loadExistingTreasuryFlowSeedConfig();
        ProtocolDeployment memory protocol = loadProtocolManifest();
        ExistingDACSeed memory existing = loadExistingDACSeedManifest(config.existingDACLabel);
        seed = loadExistingTreasuryFlowManifest(config.label);

        if (!seed.agentMinted) revert ExistingTreasuryAgentMintNotExecuted();
        if (AgentToken(seed.agentToken).balanceOf(seed.agent) < config.stakeAmount) revert ExistingTreasuryAgentMintNotExecuted();

        vm.startBroadcast(agentKey());
        Vm.Log[] memory logs = _createTreasuryDeal(seed, existing, protocol, config);
        vm.stopBroadcast();

        seed.dacProposalId = _findDealCreatedProposalId(logs);
        seed.blockNumber = block.number;

        string memory manifestPath = writeExistingTreasuryFlowManifest(seed);

        console2.log("Existing treasury flow deal created");
        console2.log("  label:", seed.label);
        console2.log("  dealId:", seed.dealId);
        console2.log("  deal:", seed.deal);
        console2.log("  dealCell:", seed.dealCell);
        console2.log("  dacProposalId:", seed.dacProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
