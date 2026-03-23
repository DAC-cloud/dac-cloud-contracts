// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleRegistry} from "../ModuleRegistry.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract ModuleRegistryFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new ModuleRegistry());
    }

    function deployModuleRegistry(address dacCell, address coreModule) external returns (address moduleRegistry) {
        bytes memory initData = abi.encodeWithSelector(
            ModuleRegistry.initialize.selector,
            dacCell,
            coreModule
        );

        moduleRegistry = address(new UUPSProxy(address(referenceImpl), initData));
    }
}
