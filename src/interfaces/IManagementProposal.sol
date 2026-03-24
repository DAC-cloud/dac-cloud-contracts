// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagementProposal {
    function id() external view returns (uint256);
    function typ() external view returns (bytes4);
    function target() external view returns (address);
    function i() external view returns (bytes32);
    function data() external view returns (bytes memory);
}
