// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WrappedMainToken} from "../src/kernel/tokens/WrappedMainToken.sol";
import {UUPSProxy} from "../src/kernel/proxies/UUPSProxy.sol";

contract MockUnderlyingToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
        vm.prank(alice);
        wrapped.wrap(100e18);

        assertEq(wrapped.balanceOf(alice), 100e18);
        assertEq(underlying.balanceOf(alice), 900e18);
        assertEq(wrapped.getVotes(alice), 100e18);
        assertEq(wrapped.delegates(alice), alice);

        vm.prank(alice);
        wrapped.unwrap(40e18);

        assertEq(wrapped.balanceOf(alice), 60e18);
        assertEq(underlying.balanceOf(alice), 940e18);
    }

    function test_wrapToDelegatesRecipient() external {
        vm.prank(alice);
        wrapped.wrapTo(bob, 55e18);

        assertEq(wrapped.balanceOf(bob), 55e18);
        assertEq(wrapped.getVotes(bob), 55e18);
        assertEq(wrapped.delegates(bob), bob);
    }
}
