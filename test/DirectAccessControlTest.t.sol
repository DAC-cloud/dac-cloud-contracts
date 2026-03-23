// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {Deal} from "../src/kernel/Deal.sol";
import {DealCell} from "../src/kernel/DealCell.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {DACManagementProposal} from "../src/kernel/governance/DACManagementProposal.sol";

contract DirectAccessControlTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public outsider = makeAddr("outsider");
    address public liquidator = makeAddr("liquidator");

    DealHandle public handle;

    bytes4 internal constant TEST_MESSAGE = bytes4(keccak256("TEST_MESSAGE"));

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);
        handle = createTreasuryDeal(agent1);
    }

    function test_tokenAdminHooks_rejectUnauthorizedCallers() public {
        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        mainToken.dacInit(outsider, outsider);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        agentToken.dacInit(outsider);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        mainToken.mint(outsider, 1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        agentToken.mint(outsider, 1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        agentToken.burnFrom(agent1, 1);
    }

    function test_agentTokenUserFacingRestrictions_rejectInvalidEntryPoints() public {
        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.InvalidDealAddress.selector);
        agentToken.transfer(outsider, 1);

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.InvalidDealAddress.selector);
        agentToken.approve(handle.dealCell, 1_000);

        vm.prank(agent1);
        vm.expectRevert(DACErrorsLib.InvalidDealAddress.selector);
        agentToken.stakeToDeal(outsider, 1_000);
    }

    function test_dealHooks_rejectNonDealCellCallers() public {
        Deal deal = Deal(handle.dealAddr);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        deal.joinDac(handle.dealCell);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        deal.beforeClose();

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        deal.onMessageDeal(TEST_MESSAGE, bytes("msg"));

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        deal.onLegalWrapperMessage(outsider, TEST_MESSAGE, bytes("wrapper"));
    }

    function test_dealCellRestrictedMethods_rejectUnauthorizedCallers() public {
        DealCell cell = DealCell(handle.dealCell);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.approveFunding(0, 1_000);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.markAsSuccess(1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.markAsFailed(1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.extendDeadline(block.timestamp + 1 days);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.recoverDeal(liquidator, 1_000);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.registerControlledAddress(outsider);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.transferCapital(address(usdc), 1);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.messageDeal(TEST_MESSAGE, bytes("msg"));

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        cell.legalWrapperMessage(outsider, TEST_MESSAGE, bytes("wrapper"));
    }

    function test_dacAndDealManagerRestrictedMethods_rejectUnauthorizedCallers() public {
        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        dac.recoverTreasury(address(usdc));

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealManager(dealManager).approveFunding(handle.dealId, 0, 0);

        vm.prank(outsider);
        vm.expectRevert(DACErrorsLib.NotAuthorized.selector);
        DealManager(dealManager).executeProp(outsider, DACManagementProposal(address(0)));

        vm.prank(outsider);
        vm.expectRevert();
        DealManager(dealManager).onDealClosed(handle.dealId);
    }
}
