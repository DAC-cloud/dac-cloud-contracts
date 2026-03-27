// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams} from "../../src/interfaces/Structs.sol";
import {CoreDealManagementType} from "../../src/modules/core/governance/CoreDealManagementProposals.sol";
import {ChildDACFlowSeed, ChildDACFlowSeedConfig} from "../common/ScriptTypes.sol";
import {ChildDACFlowBase} from "./ChildDACFlowBase.sol";

contract SeedChildDACCreateReinvestProposal is ChildDACFlowBase {
    function run() external returns (ChildDACFlowSeed memory seed) {
        ChildDACFlowSeedConfig memory config = loadChildDACFlowSeedConfig();
        seed = loadChildDACFlowManifest(config.label);

        if (!seed.childCapitalCallExecuted || seed.childCapitalCallHash == bytes32(0)) revert CapitalCallNotPrepared();

        if (_parentIsExisting(seed)) {
            vm.startBroadcast(founderKey());
            IERC20(seed.treasuryToken).transfer(seed.deal, config.reinvestAmount);
            vm.stopBroadcast();
        }

        vm.startBroadcast(agentKey());
        if (!_parentIsExisting(seed)) {
            _mintProfitsToDeal(seed.treasuryToken, seed.deal, config.reinvestAmount);
        }
        seed.reinvestProposalId = _createDealProposal(
            seed.deal,
            ProposalParams({
                typ: CoreDealManagementType.REINVEST_PROFITS,
                target: seed.treasuryToken,
                i: 0,
                data: abi.encode(config.reinvestAmount, seed.childCapitalCallHash)
            })
        );
        vm.stopBroadcast();

        seed.blockNumber = block.number;

        string memory manifestPath = writeChildDACFlowManifest(seed);

        console2.log("Child DAC reinvest proposal created");
        console2.log("  label:", seed.label);
        console2.log("  reinvestProposalId:", seed.reinvestProposalId);
        console2.log("  manifest:", manifestPath);
    }
}
