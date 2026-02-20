// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BasicEvaluator.sol";
import "./Interfaces.sol";
import "./IEvaluatorFactory.sol";

contract EvaluatorFactory is IEvaluatorFactory {
    uint256 public nextId = 1;
    mapping(address => uint256) public evaluatorsMapping;

    function deployEvaluator(bytes4 dealType, bytes calldata config) external returns (address) {
        //todo: check if the evaluator config matches dealType
        
        //todo: create a proper evaluator

        Milestone[] memory schedule = abi.decode(config, (Milestone[]));

        BasicEvaluator eval = new BasicEvaluator(schedule);
        evaluatorsMapping[address(eval)] = nextId++;

        return address(eval);
    }
}
