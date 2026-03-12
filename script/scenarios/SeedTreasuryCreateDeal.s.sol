// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {TreasuryFlowBase} from "./TreasuryFlowBase.sol";
import {BasicDACSeed, ProtocolDeployment, TreasuryFlowSeed, TreasuryFlowSeedConfig} from "../common/ScriptTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {AgentToken} from "../../src/kernel/tokens/AgentToken.sol";

contract SeedTreasuryCreateDeal is TreasuryFlowBase {
    function run() external returns (TreasuryFlowSeed memory seed) {
        TreasuryFlowSeedConfig memory config = loadTreasuryFlowSeedConfig();
        ProtocolDeployment memory protocol = loadProtocolManifest();
        BasicDACSeed memory basic = loadBasicDACSeedManifest(config.basicDACLabel);
        seed = loadTreasuryFlowManifest(config.label);

        if (!seed.agentMinted) revert AgentMintNotExecuted();
        if (AgentToken(seed.agentToken).balanceOf(seed.agent) < config.stakeAmount) revert AgentMintNotExecuted();

        vm.startBroadcast(agentKey());
        Vm.Log[] memory logs = _createTreasuryDeal(seed, basic, protocol, config);
        vm.stopBroadcast();

        seed.dacProposalId = _findDealCreatedProposalId(logs);
        seed.blockNumber = block.number;

        string memory manifestPath = writeTreasuryFlowManifest(seed);

        console2.log("Treasury flow deal created");
        console2.log("  label:", seed.label);
        console2.log("  dealId:", seed.dealId);
        console2.log("  deal:", seed.deal);
        console2.log("  dealCell:", seed.dealCell);
        console2.log("  dacProposalId:", seed.dacProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
