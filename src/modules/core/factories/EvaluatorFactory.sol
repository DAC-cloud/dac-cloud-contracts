// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../../../interfaces/IEvaluatorFactory.sol";
import "../evaluators/BasicEvaluator.sol";

contract EvaluatorFactory is IEvaluatorFactory {
    uint256 public nextId = 1;
    mapping(address => uint256) public evaluatorsMapping;

    function deployEvaluator(bytes4 dealKind, bytes calldata config) external returns (address) {
        //todo: check if the evaluator config matches dealKind
        
        //todo: create a proper evaluator

        Milestone[] memory schedule = abi.decode(config, (Milestone[]));

        BasicEvaluator eval = new BasicEvaluator(schedule);
        evaluatorsMapping[address(eval)] = nextId++;

        return address(eval);
    }
}
