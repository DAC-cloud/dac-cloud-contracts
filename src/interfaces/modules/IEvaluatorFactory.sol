// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "../Structs.sol";

interface IEvaluatorFactory {
    function deployEvaluator(
        address dac, 
        uint256 id,
        address dealCell,
        DealParams calldata deal,
        bytes calldata evaluatorConfig
    ) external returns (address);
}
