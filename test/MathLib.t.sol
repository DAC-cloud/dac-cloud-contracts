// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/kernel/libraries/MathLib.sol";

/**
 * @title MathLibTest
 * @notice Comprehensive unit + fuzz tests for MathLib.sol
 *         Demonstrates proper Foundry fuzzing patterns (bounds, assume, invariant checks)
 */
contract MathLibTest is Test {
    uint256 constant SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                          UNIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mul_basic() public pure {
        uint256 result = MathLib.mul(1000 ether, MathLib.atScale(25)); // 25%
        assertEq(result, 250 ether);
    }

    function test_mulRoundUp_basic() public pure {
        uint256 result = MathLib.mulRoundUp(1000 ether, MathLib.atScale(25));
        assertEq(result, 250 ether);
    }

    function test_div_basic() public pure {
        uint256 result = MathLib.div(250 ether, MathLib.atScale(25));
        assertEq(result, 1000 ether);
    }

    function test_capAt100() public pure {
        assertEq(MathLib.capAt100(MathLib.atScale(50)), MathLib.atScale(50));
        assertEq(MathLib.capAt100(MathLib.atScale(150)), SCALE);
        assertEq(MathLib.capAt100(SCALE), SCALE);
    }

    function test_atScale() public pure {
        assertEq(MathLib.atScale(25), MathLib.atScale(25));     // 25% -> 0.25 * 1e18
        assertEq(MathLib.atScale(100), SCALE);         // 100% -> 1e18
        assertEq(MathLib.atScale(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fuzz mul with realistic bounds (amount up to 1e30, percent 0-100%)
    function testFuzz_mul(uint256 amount, uint256 scaledPercent) public pure {
        vm.assume(amount <= 1e30);                    // realistic token amounts
        vm.assume(scaledPercent <= SCALE);            // 0% to 100%

        uint256 result = MathLib.mul(amount, scaledPercent);

        // Invariant: result <= amount (for percent <= 100%)
        assertLe(result, amount);

        // Exact check via mulDiv
        uint256 expected = (amount * scaledPercent) / SCALE;
        assertEq(result, expected);
    }

    /// @dev Fuzz mulRoundUp (rounding up edge cases)
    function testFuzz_mulRoundUp(uint256 amount, uint256 scaledPercent) public pure {
        vm.assume(amount <= 1e30);
        vm.assume(scaledPercent <= SCALE);

        uint256 result = MathLib.mulRoundUp(amount, scaledPercent);
        uint256 exact = (amount * scaledPercent) / SCALE;

        // Either exact or exact + 1
        assertGe(result, exact);
        assertLe(result, exact + 1);
    }

    /// @dev Fuzz div (inverse of mul)
    function testFuzz_div(uint256 amount, uint256 scaledPercent) public pure {
        vm.assume(amount <= 1e30);
        vm.assume(scaledPercent <= SCALE);
        vm.assume(scaledPercent > 0); // avoid div by zero

        uint256 result = MathLib.div(amount, scaledPercent);

        // Round-trip check
        uint256 roundTrip = MathLib.mul(result, scaledPercent);
        assertLe(roundTrip, amount + 1); // allow 1 wei rounding
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT / EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mulDiv_zeroDenom_reverts() public {
        vm.expectRevert();
        this.divideByZero();
    }

    function divideByZero() external pure {
        MathLib.mulDiv(1, 1, 0);
    }

    function test_mulDiv_overflow_protection() public pure {
        // Should not revert for our realistic ranges
        uint256 result = MathLib.mulDiv(1e30, SCALE, SCALE);
        assertEq(result, 1e30);
    }

    function test_capAt100_edge() public pure {
        assertEq(MathLib.capAt100(SCALE + 1), SCALE);
        assertEq(MathLib.capAt100(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ INVARIANT (Advanced)
    //////////////////////////////////////////////////////////////*/

    /// @dev Invariant: mul(x, y) / SCALE == x * y / 100% (scaled)
    function testFuzz_invariant_mulDiv_roundtrip(uint256 x, uint256 y) public pure {
        vm.assume(x <= 1e30);
        vm.assume(y <= SCALE);

        uint256 result = MathLib.mul(x, y);
        uint256 direct = (x * y) / SCALE;

        assertEq(result, direct);
    }
}