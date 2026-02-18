// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IEvaluator.sol";
import "./Interfaces.sol";
import "./IDeal.sol";

contract BasicEvaluator is IEvaluator {
    Milestone[] public schedule;

    constructor(Milestone[] memory _schedule) {
        for (uint256 i = 0; i < _schedule.length; i++) {
            schedule.push(_schedule[i]);
        }
    }

    function evaluateDeal(uint256, address dealAddr, address) external view returns (EvaluationResult memory) {
        uint256 returned = IDeal(dealAddr).getReturnedCapital();
        uint256 currentTime = block.timestamp;

        // Find the relevant milestone
        uint256 expected = 0;
        for (uint256 i = 0; i < schedule.length; i++) {
            if (currentTime >= schedule[i].timestamp) {
                expected = schedule[i].expectedReturnPercent;
            } else {
                break;
            }
        }

        //todo: returning not 100%, but as set by reward percentage in the milestone
        //  think about calculations that makes sense economically for real projects
        
        if (returned >= expected) {
            return EvaluationResult(1, 100, 0); // convert 100%
        } else if (currentTime > IDeal(dealAddr).dealDeadline()) {
            return EvaluationResult(0, 100, 0); // slash 100%
        } else {
            return EvaluationResult(2, 0, currentTime + 30 days); // extend 30 days
        }
    }
}