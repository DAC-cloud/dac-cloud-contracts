// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BasicGovernanceOracle} from "../BasicGovernanceOracle.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract GovernanceOracleFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new BasicGovernanceOracle());
    }

    function deployGovernanceOracle(address admin, address initialPublisher) external returns (address oracle) {
        bytes memory initData = abi.encodeWithSelector(
            BasicGovernanceOracle.initialize.selector,
            admin,
            initialPublisher
        );

        oracle = address(new UUPSProxy(referenceImpl, initData));
    }
}
