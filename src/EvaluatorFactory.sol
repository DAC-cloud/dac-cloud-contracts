// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BasicEvaluator.sol";

contract EvaluatorFactory {
    function deployBasicEvaluator() external returns (address) {
        return address(new BasicEvaluator());
    }
}