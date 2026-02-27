// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IClock {
    /**
     * @dev ERC-6372 clock standard
     */
    function clock() external view returns (uint48);
    function CLOCK_MODE() external pure returns (string memory);
}