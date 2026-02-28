// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDACCellAdapter {
    function depositTreasury(address token, uint256 amount) external;
    function getMainToken() external view returns (address);
    function getAgentToken() external view returns (address);
    function dealManager() external view returns (address);
}