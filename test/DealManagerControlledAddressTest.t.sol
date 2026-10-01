// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACTestBase} from "./base/DACTestBase.t.sol";
import {DealManager} from "../src/kernel/DealManager.sol";
import {IAssetController} from "../src/interfaces/IAssetController.sol";
import {IVotes} from "../src/lib/IVotes.sol";
import {DACErrorsLib} from "../src/interfaces/DACErrorsLib.sol";
import {TreasuryDeal} from "../src/modules/core/deals/TreasuryDeal.sol";

/// Stand-in for a pool / vault: a contract account that never delegates.
contract PassiveVault {}

/// Stand-in for a Safe or smart account that participates in governance.
contract VotingVault {
    function delegate(address token, address to) external {
        IVotes(token).delegate(to);
    }
}

/// M-2 regression: a Deal module may register at most MAX_MODULE_CONTROLLED_ADDRESSES
/// controlled addresses beyond the kernel pair (DealCell + Deal). Only contract
/// accounts (not EOAs, not EIP-7702 delegated EOAs) that never delegated qualify.
/// Balances and incoming delegations are allowed: undelegated tokens cannot vote.
contract DealManagerControlledAddressTest is DACTestBase {
    address public agent1 = makeAddr("agent1");
    address public outsider = makeAddr("outsider");

    DealManager internal manager;
    IAssetController internal controller;

    function setUp() public {
        setUpBase();
        onboardAgent(agent1);

        manager = DealManager(dealManager);
        controller = IAssetController(dac.getAssetController());
    }

    function _vault() internal returns (address) {
        return address(new PassiveVault());
    }

    function test_kernelPairAndModuleTreasuryAreControlled() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        assertTrue(controller.isControlledAddress(handle.dealCell));
        assertTrue(controller.isControlledAddress(handle.dealAddr));
        assertTrue(controller.isControlledAddress(TreasuryDeal(handle.dealAddr).managedEntity()));

        // Kernel pair is not counted against the module budget; the treasury is.
        assertEq(manager.moduleControlledCount(handle.dealCell), 1);
    }

    function test_moduleControlledAddresses_cappedPerDeal() public {
        DealHandle memory handle = createTreasuryDeal(agent1);
        uint256 max = manager.MAX_MODULE_CONTROLLED_ADDRESSES();
        assertEq(max, 3);

        address v1 = _vault();
        address v2 = _vault();
        address v3 = _vault();

        vm.startPrank(handle.dealCell);

        manager.registerControlledAddress(v1);
        manager.registerControlledAddress(v2);
        assertEq(manager.moduleControlledCount(handle.dealCell), max);

        vm.expectRevert(DACErrorsLib.ControlledAddressLimitReached.selector);
        manager.registerControlledAddress(v3);

        // Re-registering an already-controlled address is a no-op, not a budget hit.
        manager.registerControlledAddress(v1);
        manager.registerControlledAddress(handle.dealAddr);
        assertEq(manager.moduleControlledCount(handle.dealCell), max);

        vm.stopPrank();

        assertTrue(controller.isControlledAddress(v1));
        assertTrue(controller.isControlledAddress(v2));
        assertFalse(controller.isControlledAddress(v3));
    }

    function test_moduleControlledAddresses_independentPerDeal() public {
        DealHandle memory first = createTreasuryDeal(agent1);
        DealHandle memory second = createTreasuryDeal(agent1);

        assertEq(manager.moduleControlledCount(first.dealCell), 1);
        assertEq(manager.moduleControlledCount(second.dealCell), 1);

        vm.startPrank(first.dealCell);
        manager.registerControlledAddress(_vault());
        manager.registerControlledAddress(_vault());
        vm.stopPrank();

        address overflow = _vault();
        vm.startPrank(second.dealCell);
        manager.registerControlledAddress(_vault());
        manager.registerControlledAddress(_vault());
        vm.expectRevert(DACErrorsLib.ControlledAddressLimitReached.selector);
        manager.registerControlledAddress(overflow);
        vm.stopPrank();
    }

    function test_moduleCannotControlEOA() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        // Token-holding EOA (founder) and empty EOA alike.
        assertGt(mainToken.balanceOf(founder), 0);

        vm.startPrank(handle.dealCell);

        vm.expectRevert(DACErrorsLib.ControlledAddressNotContract.selector);
        manager.registerControlledAddress(founder);

        vm.expectRevert(DACErrorsLib.ControlledAddressNotContract.selector);
        manager.registerControlledAddress(makeAddr("empty-eoa"));

        vm.stopPrank();

        assertFalse(controller.isControlledAddress(founder));
        assertEq(manager.moduleControlledCount(handle.dealCell), 1);
    }

    function test_moduleCannotControl7702DelegatedEOA() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        address whale = makeAddr("7702-whale");
        vm.etch(whale, abi.encodePacked(hex"ef0100", address(new PassiveVault())));
        assertEq(whale.code.length, 23);

        vm.prank(handle.dealCell);
        vm.expectRevert(DACErrorsLib.ControlledAddressNotContract.selector);
        manager.registerControlledAddress(whale);
    }

    function test_moduleCannotControlContractThatDelegated() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        VotingVault safe = new VotingVault();
        vm.prank(founder);
        mainToken.transfer(address(safe), 1_000e18);
        safe.delegate(address(mainToken), address(safe));
        assertEq(mainToken.delegates(address(safe)), address(safe));

        vm.prank(handle.dealCell);
        vm.expectRevert(DACErrorsLib.ControlledAddressHasVotingPower.selector);
        manager.registerControlledAddress(address(safe));

        // Delegating outward counts the same: the contract is a governance participant.
        VotingVault safe2 = new VotingVault();
        safe2.delegate(address(mainToken), makeAddr("representative"));

        vm.prank(handle.dealCell);
        vm.expectRevert(DACErrorsLib.ControlledAddressHasVotingPower.selector);
        manager.registerControlledAddress(address(safe2));
    }

    /// The LP / vault use case: a contract holding main tokens that never delegated
    /// is custody, not a voter, and may be excluded from governance.
    function test_moduleCanControlTokenHoldingPassiveContract() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        address pool = _vault();
        vm.prank(founder);
        mainToken.transfer(pool, 50_000_000e18);
        assertEq(mainToken.delegates(pool), address(0));

        vm.prank(handle.dealCell);
        manager.registerControlledAddress(pool);

        assertTrue(controller.isControlledAddress(pool));

        // Once controlled, the pool can never start delegating.
        vm.prank(pool);
        vm.expectRevert(DACErrorsLib.NoVotingPower.selector);
        mainToken.delegate(pool);
    }

    /// Incoming delegations do not block registration: the delegators' balances
    /// stay in the votable total, so yes-votes can never exceed it.
    function test_moduleCanControlContractWithIncomingDelegation() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        address representative = _vault();
        vm.prank(founder);
        mainToken.delegate(representative);
        assertGt(mainToken.getVotes(representative), 0);
        assertEq(mainToken.delegates(representative), address(0));

        uint256 votableBefore = controller.totalReleasedVotable();

        vm.prank(handle.dealCell);
        manager.registerControlledAddress(representative);

        assertTrue(controller.isControlledAddress(representative));
        assertEq(controller.totalReleasedVotable(), votableBefore);
        assertEq(mainToken.getVotes(representative), mainToken.balanceOf(founder));
    }

    /// Griefing regression: nobody but the address itself can set its delegation, so a
    /// third party cannot pre-poison an address a deal is about to register.
    function test_thirdPartyCannotPoisonDelegationOfFutureControlledAddress() public {
        DealHandle memory handle = createTreasuryDeal(agent1);

        address predicted = _vault();

        // Attacker funds it and delegates to it; neither sets delegates(predicted).
        vm.startPrank(founder);
        mainToken.transfer(predicted, 1);
        mainToken.delegate(predicted);
        vm.stopPrank();
        assertEq(mainToken.delegates(predicted), address(0));

        vm.prank(handle.dealCell);
        manager.registerControlledAddress(predicted);
        assertTrue(controller.isControlledAddress(predicted));
    }

    function test_registerControlledAddress_rejectsNonDealCell() public {
        createTreasuryDeal(agent1);
        address v = _vault();

        vm.prank(outsider);
        vm.expectRevert();
        manager.registerControlledAddress(v);

        vm.prank(founder);
        vm.expectRevert();
        manager.registerControlledAddress(v);
    }
}
