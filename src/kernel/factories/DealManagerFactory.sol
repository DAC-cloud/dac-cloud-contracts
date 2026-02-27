// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealManager} from "../DealManager.sol";

library DealManagerFactory {
    
    function deployDealManager(
        address mainToken,
        address agentToken,
        address coreModule,
        address dacCell
    ) external returns (address dealManager) {
        dealManager = address(new DealManager());

        DealManager(dealManager).initializeAfterDeployment(
            mainToken,
            agentToken,
            coreModule,
            dacCell
        );
    }
}