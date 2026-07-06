// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSProxy} from "../../src/kernel/proxies/UUPSProxy.sol";

/// @dev Test-only proxy that permits construction with empty init data.
/// OZ v5.2.0 made `ERC1967Proxy` revert with `ERC1967ProxyUninitialized()` when
/// deployed without an init call. Several unit tests intentionally deploy a bare
/// proxy and then call `initialize(...)` with per-test parameters afterwards.
/// This helper restores that behavior for tests ONLY — production code must keep
/// using `UUPSProxy`, which always deploys with real init data.
contract TestUUPSProxy is UUPSProxy {
    constructor(address implementation, bytes memory initData)
        UUPSProxy(implementation, initData)
    {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
