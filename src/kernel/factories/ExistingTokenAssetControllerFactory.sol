// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ExistingTokenAssetController} from "../controllers/ExistingTokenAssetController.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract ExistingTokenAssetControllerFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new ExistingTokenAssetController());
    }

    function deployExistingTokenAssetController(address dacCell, address wrappedMainToken)
        external
        returns (address assetController)
    {
        bytes memory initData = abi.encodeWithSelector(
            ExistingTokenAssetController.initialize.selector,
            dacCell,
            wrappedMainToken
        );

        assetController = address(new UUPSProxy(referenceImpl, initData));
    }
}
