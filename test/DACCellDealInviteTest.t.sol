// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MathLib} from "../src/kernel/libraries/MathLib.sol";
import {DACCell} from "../src/kernel/DACCell.sol";
import {MainToken} from "../src/kernel/tokens/MainToken.sol";
import {AgentToken} from "../src/kernel/tokens/AgentToken.sol";
import {StakedAgent} from "../src/kernel/tokens/StakedAgent.sol";
import {DACManagementProposalFactory} from "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import {DealManagerFactory} from "../src/kernel/factories/DealManagerFactory.sol";
import {DealCellFactory} from "../src/kernel/factories/DealCellFactory.sol";
import {DACFactory} from "../src/kernel/DACFactory.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {IDealManager} from "../src/interfaces/IDealManager.sol";
import {IDealCell} from "../src/interfaces/IDealCell.sol";
import {IVoting} from "../src/interfaces/IVoting.sol";
import {IDACFactory} from "../src/interfaces/IDACFactory.sol";
import {CoreModuleFactory} from "../src/modules/core/CoreModuleFactory.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";
import {DACDealFactory} from "../src/modules/core/deals/factories/DACDealFactory.sol";
import {TreasuryDealFactory} from "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import {MilestoneBasedEvaluator} from "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {MilestoneEvaluatorFactory} from "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import {RevenueEvaluatorFactory} from "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import {CoreManagementProposalFactory} from "../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import {DACDeal} from "../src/modules/core/deals/DACDeal.sol";
import {DACTestBase, MockUSDC} from "./base/DACTestBase.t.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";

contract DACCellDealTest is DACTestBase {
    
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    function setUp() public {
        setUpBase();

        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function testUnstakeBeforeApprove() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.stopPrank();

        vm.startPrank(agent1);
        vm.expectRevert(DACErrorsLib.DeadlineNotPassed.selector);
        IDealCell(handle.dealCell).unstake();
    }

    function testStakeWithoutInvite() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        StakedAgent(IDealCell(handle.dealCell).stakeToken()).delegate(agent1);
        vm.stopPrank();

        vm.startPrank(agent2);
        vm.expectRevert(DACErrorsLib.NotWhitelistedAgent.selector);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.stopPrank();
    }

    function testStakeWithInvite() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        StakedAgent(IDealCell(handle.dealCell).stakeToken()).delegate(agent1);

        IDealCell(handle.dealCell).invite(agent2, true);

        vm.stopPrank();

        vm.startPrank(agent2);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        StakedAgent(IDealCell(handle.dealCell).stakeToken()).delegate(agent1);
        vm.stopPrank();

        assertEq(IERC20(IDealCell(handle.dealCell).stakeToken()).balanceOf(agent2), 20_000, "Staked token transferred to agent");
    }

    function testUnstakeAfterDeadline() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(agent1);
        IDealCell(handle.dealCell).unstake();
    }
}