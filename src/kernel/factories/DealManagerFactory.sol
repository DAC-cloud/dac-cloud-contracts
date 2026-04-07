// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealManager} from "../DealManager.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract DealManagerFactory {
    
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new DealManager());
    }

    function deployDealManager(
        address mainToken,
        address agentToken,
        address moduleRegistry,
        address dacCell,
        address assetController,
        address dealCellFactory,
        address stakedAgentTokenFactory
    ) external returns (address dealManager) {
        bytes memory initData = abi.encodeWithSelector(
            DealManager.initialize.selector,
            mainToken,
            agentToken,
            moduleRegistry,
            dacCell,
            assetController,
            dealCellFactory,
            stakedAgentTokenFactory
        );

        dealManager = address(new UUPSProxy(address(referenceImpl), initData));
    }
}
