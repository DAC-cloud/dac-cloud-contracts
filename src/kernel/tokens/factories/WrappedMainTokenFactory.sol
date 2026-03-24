// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WrappedMainToken} from "../WrappedMainToken.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract WrappedMainTokenFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new WrappedMainToken());
    }

    function deployWrappedMainToken(
        address underlying,
        string memory name,
        string memory symbol,
        address admin
    ) external returns (address wrappedToken) {
        bytes memory initData = abi.encodeWithSelector(
            WrappedMainToken.initialize.selector,
            underlying,
            name,
            symbol,
            admin
        );

        wrappedToken = address(new UUPSProxy(referenceImpl, initData));
    }
}
