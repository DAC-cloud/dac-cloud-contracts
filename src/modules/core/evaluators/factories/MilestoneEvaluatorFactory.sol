// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSProxy} from "../../../../kernel/proxies/UUPSProxy.sol";
import {DealParams} from "../../../../interfaces/Structs.sol";
import {IEvaluatorFactory} from "../../../../interfaces/modules/IEvaluatorFactory.sol";
import {MilestoneBasedEvaluator} from "../MilestoneBasedEvaluator.sol";

contract MilestoneEvaluatorFactory is IEvaluatorFactory {
    
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new MilestoneBasedEvaluator());
    }

    function deployEvaluator(
        address dac, 
        uint256 id, 
        address cell, 
        DealParams calldata, 
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr) {
        bytes memory initData = abi.encodeWithSelector(
            MilestoneBasedEvaluator.initialize.selector,
            dac,
            id,
            cell,
            evaluatorConfig
        );

        evaluatorAddr = address(new UUPSProxy(address(referenceImpl), initData));
    }
}