// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IModuleRegistry {
    function isModuleApproved(address moduleFactory) external view returns (bool);
    function approveModule(address moduleFactory) external;
    function removeModule(address moduleFactory) external;
}
