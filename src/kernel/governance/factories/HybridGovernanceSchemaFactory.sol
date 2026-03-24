// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceStrategyConfig} from "../../../interfaces/GovernanceStructs.sol";
import {HybridGovernanceSchema} from "../HybridGovernanceSchema.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract HybridGovernanceSchemaFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new HybridGovernanceSchema());
    }

    function deployHybridGovernanceSchema(
        address dacCell,
        address wrappedMainToken,
        address dealManager,
        address assetController,
        address proposalFactory,
        address governanceOracle,
        GovernanceStrategyConfig calldata strategyConfig
    ) external returns (address governanceSchema) {
        bytes memory initData = abi.encodeWithSelector(
            HybridGovernanceSchema.initialize.selector,
            dacCell,
            wrappedMainToken,
            dealManager,
            assetController,
            proposalFactory,
            governanceOracle,
            strategyConfig
        );

        governanceSchema = address(new UUPSProxy(referenceImpl, initData));
    }
}
