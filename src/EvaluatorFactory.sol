// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BasicEvaluator.sol";

contract EvaluatorFactory {
    uint256 public nextId = 1;

    mapping(address => uint256) public evaluatorsMapping;

    function isValidEvaluator(address evaluator) external view returns (bool) {
        return evaluatorsMapping[evaluator] != 0;
    }

    function deployBasicEvaluator() external returns (address) {
        return address(new BasicEvaluator());
    }
}