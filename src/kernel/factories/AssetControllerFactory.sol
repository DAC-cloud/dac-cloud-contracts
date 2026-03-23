// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NativeAssetController} from "../controllers/NativeAssetController.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract NativeAssetControllerFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new NativeAssetController());
    }

    function deployNativeAssetController(address dacCell, address mainToken) external returns (address assetController) {
        bytes memory initData = abi.encodeWithSelector(
            NativeAssetController.initialize.selector,
            dacCell,
            mainToken
        );

        assetController = address(new UUPSProxy(address(referenceImpl), initData));
    }
}
