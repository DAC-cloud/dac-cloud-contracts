// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VotingConfig} from "../../../interfaces/Structs.sol";
import {NativeGovernanceSchema} from "../NativeGovernanceSchema.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract NativeGovernanceSchemaFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new NativeGovernanceSchema());
    }

    function deployNativeGovernanceSchema(
        address dacCell,
        address mainToken,
        address dealManager,
        address proposalFactory,
        VotingConfig calldata votingConfig
    ) external returns (address governanceSchema) {
        bytes memory initData = abi.encodeWithSelector(
            NativeGovernanceSchema.initialize.selector,
            dacCell,
            mainToken,
            dealManager,
            proposalFactory,
            votingConfig
        );

        governanceSchema = address(new UUPSProxy(referenceImpl, initData));
    }
}
