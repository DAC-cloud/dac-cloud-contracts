// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IModuleRegistry} from "../interfaces/IModuleRegistry.sol";
import {DACErrorsLib} from "../interfaces/DACErrorsLib.sol";

contract ModuleRegistry is IModuleRegistry {
    address public immutable dacCell;
    address public immutable coreModule;

    mapping(address => bool) private approvedModules;

    constructor(address _dacCell, address _coreModule) {
        require(_dacCell != address(0), DACErrorsLib.NotAllowed());
        require(_coreModule != address(0), DACErrorsLib.NotAllowed());

        dacCell = _dacCell;
        coreModule = _coreModule;
        approvedModules[_coreModule] = true;
    }

    function isModuleApproved(address moduleFactory) external view returns (bool) {
        return approvedModules[moduleFactory];
    }

    function approveModule(address moduleFactory) external onlyDACCell {
        require(moduleFactory != address(0), DACErrorsLib.NotAllowed());
        approvedModules[moduleFactory] = true;
    }

    function removeModule(address moduleFactory) external onlyDACCell {
        require(moduleFactory != address(0), DACErrorsLib.NotAllowed());
        require(moduleFactory != coreModule, DACErrorsLib.NotAllowed());
        approvedModules[moduleFactory] = false;
    }

    modifier onlyDACCell() {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());
        _;
    }
}
