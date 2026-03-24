// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {ProposalParams, DealParams} from "../src/interfaces/Structs.sol";
import {DealCreationConfig} from "../src/interfaces/GovernanceStructs.sol";
import {DACManagementProposalType} from "../src/kernel/governance/DACManagementProposals.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {CoreDealType, CoreEvaluatorType} from "../src/modules/core/CoreModuleDeals.sol";
import {Milestone} from "../src/modules/core/interfaces/Structs.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";

contract DealCreationConfigTest is Test, DACTestBase {
    address internal agent = makeAddr("agent");

    function setUp() external {
        setUpBase();
        onboardAgent(agent);
    }

    function test_updateDealCreationConfig_forcesInitialStakeOnDealCreation() external {
        _setDealCreationConfig(50_000, 10_000);

        DealParams memory params = _treasuryParams(agent);

        vm.prank(agent);
        (uint256 dealId, address dealCell,,) = IDealManager(dealManager).createDealProposal(params);

        assertEq(dealId, 1);
        assertEq(ERC20(IDealCell(dealCell).stakeToken()).balanceOf(agent), 10_000);
        assertEq(agentToken.balanceOf(agent), 90_000);
    }

    function test_updateDealCreationConfig_blocksUnderqualifiedAgents() external {
        _setDealCreationConfig(200_000, 10_000);

        DealParams memory params = _treasuryParams(agent);

        vm.expectRevert();
        vm.prank(agent);
        IDealManager(dealManager).createDealProposal(params);
    }

    function _setDealCreationConfig(uint256 minAgentBalance, uint256 minInitialAgentStake) internal {
        vm.startPrank(founder);

        uint256 proposalId = dac.createManagementProposal(
            ProposalParams({
                typ: DACManagementProposalType.UPDATE_DEAL_CREATION_CONFIG,
                target: address(0),
                i: bytes32(0),
                data: abi.encode(
                    DealCreationConfig({
                        minAgentBalance: minAgentBalance,
                        minInitialAgentStake: minInitialAgentStake
                    })
                )
            })
        );

        vm.warp(block.timestamp + 1);
        IVoting(dac.getProposalVoting(proposalId)).vote(true);
        dac.executeDACProposal(proposalId);

        vm.stopPrank();
    }

    function _treasuryParams(address proposer) internal view returns (DealParams memory params) {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({
            milestoneType: 0,
            token: address(usdc),
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 10_000e6,
            timestamp: block.timestamp + 1 days,
            rewardPercentage: 1e18,
            rewardCurve: new int256[](1),
            penaltyCurve: new int256[](1),
            minPercentGrace: 0,
            extension: 0
        });
        milestones[0].rewardCurve[0] = int256(MathLib.SCALE);
        milestones[0].penaltyCurve[0] = int256(MathLib.SCALE);

        MilestoneBasedEvaluator.Config memory evaluatorCfg =
            MilestoneBasedEvaluator.Config(MathLib.atScale(100), milestones);

        params = DealParams({
            dealKind: CoreDealType.PERMIT2_TREASURY,
            name: "Qualified Treasury Deal",
            description: "Qualified Treasury Deal description",
            linkHash: "0x00112233",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGovernanceFactory),
            dealTarget: address(0),
            proposer: proposer,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: 10_000,
            rewardsLimit: 500e6,
            approveDeadline: block.timestamp + 1 days,
            evaluationDeadline: block.timestamp + 15 days,
            dealDeadline: block.timestamp + 30 days,
            evaluatorSelector: CoreEvaluatorType.MILESTONES_EVALUATOR,
            dealConfig: abi.encode("deal config"),
            evaluatorConfig: abi.encode(evaluatorCfg)
        });
    }
}
