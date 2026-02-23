// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";

interface IDACEntityAdapter {
    function mintLP(address deal, address to, uint256 amount) external;
    function depositTreasury(address token, uint256 amount) external;
    function createTrancheProposal(uint256 dealId, uint256 trancheId) external;
    function getLPToken() external view returns (address);
}