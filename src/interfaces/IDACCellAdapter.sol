// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface IDACCellAdapter {
    // function registerAddress(address deal, address controlled) external;
    // function onMainMove(address from, address to, uint256 amount) external;
    function depositTreasury(address token, uint256 amount) external;
    function getMainToken() external view returns (address);
    function dealManager() external view returns (address);
}