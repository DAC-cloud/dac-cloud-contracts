// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../../../interfaces/modules/IEvaluatorFactory.sol";
import "../evaluators/BasicEvaluator.sol";

contract BasicEvaluatorFactory is IEvaluatorFactory {
    uint256 public nextId = 1;
    mapping(address => uint256) public evaluatorsMapping;

    function deployEvaluator(address dac, uint256 id, address cell, DealParams calldata params) external returns (address) {
        Milestone[] memory schedule = abi.decode(params.evaluatorConfig, (Milestone[]));

        BasicEvaluator eval = new BasicEvaluator(dac, id, cell, schedule);
        evaluatorsMapping[address(eval)] = nextId++;

        return address(eval);
    }
}
