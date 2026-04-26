// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MathLib
 * @notice 18-decimal fixed-point math for all DAC percentage operations.
 *         All functions expect SCALED percentages (100% = 100 * 1e18).
 *         mulDiv delegates to OpenZeppelin Math.mulDiv (full 512-bit precision).
 */
library MathLib {
    uint256 public constant SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                          CORE MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev x * y / denominator with full 512-bit precision and overflow protection.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return Math.mulDiv(x, y, denominator);
    }

    /// @dev Safe signed fixed-point multiply-divide (handles negative coeffs)
    function mulDivSigned(int256 x, int256 y, uint256 scale) internal pure returns (int256) {
        // casting to 'uint256' is safe here since calculating `abs`
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 ux = x < 0 ? uint256(-x) : uint256(x);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 uy = y < 0 ? uint256(-y) : uint256(y);
        
        uint256 res = mulDiv(ux, uy, scale);
        
        // forge-lint: disable-next-line(unsafe-typecast)
        return (x ^ y) < 0 ? -int256(res) : int256(res);
    }

    /*//////////////////////////////////////////////////////////////
                          SCALED PERCENTAGE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev amount * scaledPercent / SCALE
     *      Example: 1000e18 * 25e18 / 1e18 = 250e18
     */
    function mul(uint256 amount, uint256 scaledPercent) internal pure returns (uint256) {
        return mulDiv(amount, scaledPercent, SCALE);
    }

    /**
     * @dev amount * scaledPercent / SCALE with rounding up (useful for penalties)
     */
    function mulRoundUp(uint256 amount, uint256 scaledPercent) internal pure returns (uint256) {
        return (amount * scaledPercent + SCALE - 1) / SCALE;
    }

    /**
     * @dev amount / scaledPercent * SCALE
     */
    function div(uint256 amount, uint256 scaledPercent) internal pure returns (uint256) {
        return mulDiv(amount, SCALE, scaledPercent);
    }

    /*//////////////////////////////////////////////////////////////
                          SCALED PERCENTAGE OPERATIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Convert not-scaled percent to scaled
     *      Example 25% becomes 2.5e17
     *              100% becomes exact SCALE = 1e18
     */
    function atScale(uint256 value) internal pure returns (uint256) {
        return mulDiv(value, SCALE, 100);
    }
    
    /**
     * @dev Caps any scaled value at 100% (SCALE)
     */
    function capAt100(uint256 scaledValue) internal pure returns (uint256) {
        return scaledValue > SCALE ? SCALE : scaledValue;
    }
}