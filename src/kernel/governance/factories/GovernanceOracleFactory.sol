// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceOracle} from "../GovernanceOracle.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract GovernanceOracleFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new GovernanceOracle());
    }

    function deployGovernanceOracle(address admin, address initialPublisher) external returns (address oracle) {
        bytes memory initData = abi.encodeWithSelector(
            GovernanceOracle.initialize.selector,
            admin,
            initialPublisher
        );

        oracle = address(new UUPSProxy(referenceImpl, initData));
    }
}
