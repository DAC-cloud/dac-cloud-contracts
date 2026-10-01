// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DACEventsLib} from "../src/interfaces/DACEventsLib.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MockUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Underlying with a sender-side hook (ERC777-style): calls back into the wrapper
/// from inside transferFrom, before any balance moves.
contract HookedUnderlyingToken is ERC20 {
    WrappedMainToken public wrapped;
    bool public armed;

    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function arm(WrappedMainToken _wrapped) external { wrapped = _wrapped; armed = true; }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            // Nested wrap observes the same balanceBefore as the outer one.
            wrapped.wrapTo(from, amount);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract WrappedMainTokenTest is Test {
    MockUnderlyingToken internal underlying;
    WrappedMainToken internal wrapped;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() external {
        underlying = new MockUnderlyingToken();
        wrapped = WrappedMainToken(
            address(
                new UUPSProxy(
                    address(new WrappedMainToken()),
                    abi.encodeWithSelector(
                        WrappedMainToken.initialize.selector,
                        address(underlying),
                        "Wrapped DAC",
                        "wDAC",
                        address(this)
                    )
                )
            )
        );

        underlying.mint(alice, 1_000e18);

        vm.prank(alice);
        underlying.approve(address(wrapped), type(uint256).max);
    }

    function test_wrapAutoDelegatesAndUnwrapsOneToOne() external {
        vm.expectEmit(true, true, false, true, address(wrapped));
        emit DACEventsLib.Wrapped(alice, alice, 100e18);
        vm.prank(alice);
        wrapped.wrap(100e18);

        assertEq(wrapped.balanceOf(alice), 100e18);
        assertEq(underlying.balanceOf(alice), 900e18);
        assertEq(wrapped.getVotes(alice), 100e18);
        assertEq(wrapped.delegates(alice), alice);

        vm.expectEmit(true, true, false, true, address(wrapped));
        emit DACEventsLib.Unwrapped(alice, alice, 40e18);
        vm.prank(alice);
        wrapped.unwrap(40e18);

        assertEq(wrapped.balanceOf(alice), 60e18);
        assertEq(underlying.balanceOf(alice), 940e18);
    }

    /// Third-party wraps must not set the recipient's delegation: that would let
    /// anyone pre-poison `delegates(x)` for an address a deal is about to register
    /// as controlled. Recipients delegate themselves.
    function test_wrapToDoesNotDelegateRecipient() external {
        vm.expectEmit(true, true, false, true, address(wrapped));
        emit DACEventsLib.Wrapped(alice, bob, 55e18);
        vm.prank(alice);
        wrapped.wrapTo(bob, 55e18);

        assertEq(wrapped.balanceOf(bob), 55e18);
        assertEq(wrapped.getVotes(bob), 0);
        assertEq(wrapped.delegates(bob), address(0));

        vm.prank(bob);
        wrapped.delegate(bob);
        assertEq(wrapped.getVotes(bob), 55e18);
    }

    /// Balance-delta accounting must not be re-enterable through underlying hooks, or
    /// the nested wrap's deposit is counted twice and minted unbacked.
    function test_wrap_rejectsReentrancyThroughUnderlyingHook() external {
        HookedUnderlyingToken hooked = new HookedUnderlyingToken();
        WrappedMainToken hookedWrapped = WrappedMainToken(
            address(
                new UUPSProxy(
                    address(new WrappedMainToken()),
                    abi.encodeWithSelector(
                        WrappedMainToken.initialize.selector, address(hooked), "Wrapped Hooked", "wHOOK", address(this)
                    )
                )
            )
        );

        hooked.mint(alice, 100e18);
        hooked.mint(address(hooked), 100e18);
        vm.prank(alice);
        hooked.approve(address(hookedWrapped), type(uint256).max);
        vm.prank(address(hooked));
        hooked.approve(address(hookedWrapped), type(uint256).max);

        hooked.arm(hookedWrapped);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookedWrapped.wrap(50e18);

        assertEq(hookedWrapped.totalSupply(), 0);
    }

    function test_selfWrapAutoDelegates() external {
        vm.prank(alice);
        wrapped.wrapTo(alice, 10e18);

        assertEq(wrapped.delegates(alice), alice);
        assertEq(wrapped.getVotes(alice), 10e18);
    }
}
