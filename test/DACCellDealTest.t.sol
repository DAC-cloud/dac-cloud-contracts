// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/kernel/DACCell.sol";
import "../src/kernel/tokens/MainToken.sol";
import "../src/kernel/tokens/AgentToken.sol";
import "../src/kernel/tokens/StakedAgent.sol";
import "../src/kernel/tokens/factories/TokenFactories.sol";
import "../src/kernel/governance/factories/DACManagementProposalFactory.sol";
import "../src/kernel/factories/DealManagerFactory.sol";
import "../src/kernel/factories/DealCellFactory.sol";
import "../src/kernel/DACFactory.sol";
import "../src/kernel/Deal.sol";
import "../src/kernel/libraries/MathLib.sol";
import "../src/interfaces/IDACFactory.sol";
import "../src/interfaces/Structs.sol";
import "../src/modules/core/CoreModuleFactory.sol";
import "../src/modules/core/deals/factories/DACDealFactory.sol";
import "../src/modules/core/deals/factories/TreasuryDealFactory.sol";
import "../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import "../src/modules/core/evaluators/factories/MilestoneEvaluatorFactory.sol";
import "../src/modules/core/evaluators/factories/RevenueEvaluatorFactory.sol";
import "../src/modules/core/governance/factories/CoreDealManagementProposalFactory.sol";
import "../src/modules/core/interfaces/Structs.sol";
import "../src/modules/core/deals/DACDeal.sol";
import "./base/DACTestBase.t.sol";

contract DACCellDealTest is DACTestBase {
    
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");

    function setUp() public {
        setUpBase();

        onboardAgent(agent1);
        onboardAgent(agent2);
    }

    function testTreasuryDeal() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        assertEq(IDealCell(IDealManager(dac.getDealManager()).deals(handle.dealId)).name(), "Test Treasury Deal", "deal name by id wiring");

        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        StakedAgent(IDealCell(handle.dealCell).stakeToken()).delegate(agent1);
        vm.stopPrank();

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();

        address treasuryAddr = TreasuryDeal(handle.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(treasuryAddr), 10_000, "Balance transferred to treasury");
    }

    function testDACDeal() public {
        DealHandle memory handle = createDACDeal(agent1);

        vm.warp(block.timestamp + 1);

        vm.startPrank(agent1);
        agentToken.stakeToDeal(handle.dealCell, 20_000);
        StakedAgent(IDealCell(handle.dealCell).stakeToken()).delegate(agent1);
        vm.stopPrank();

        vm.startPrank(founder);
        IVoting(dac.getProposalVoting(handle.proposalId)).vote(true);
        dac.executeDACProposal(handle.proposalId);
        vm.stopPrank();

        address childDac = DACDeal(handle.dealAddr).managedEntity();
        assertEq(usdc.balanceOf(childDac), 10_000, "Balance transferred to child");
    }
} 