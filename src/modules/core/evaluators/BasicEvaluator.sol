// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";
import "../../../interfaces/IEvaluator.sol";
import "../../../interfaces/IDealCore.sol";
import "../interfaces/Structs.sol";

contract BasicEvaluator is IEvaluator {
    address public immutable dac;
    uint256 public immutable deal;
    Milestone[] public schedule;

    constructor(address _dac, uint256 _deal, Milestone[] memory _schedule) {
        dac = _dac;
        deal = _deal;
        for (uint256 i = 0; i < _schedule.length; i++) {
            schedule.push(_schedule[i]);
        }
    }

    function evaluateDeal(uint256, address dealAddr, address) external view returns (EvaluationResult memory) {
        uint256 returned = 0; // IDealCore(dealAddr).getReturnedCapital(token);
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

        // todo: for DAC deals need to also have an oracle proxy for pricing
        //  lp equity in the escrow, as this equity calculates into the deal
        //  and have the only way to be returned natively to DAC balance sheet

        // todo: returning not 100%, but as set by reward percentage in the milestone
        //  think about calculations that makes sense economically for real projects
        
        if (returned >= expected) {
            return EvaluationResult(1, 100, 0); // convert 100%
        } else if (currentTime > IDealCore(dealAddr).dealDeadline()) {
            return EvaluationResult(0, 100, 0); // slash 100%
        } else {
            return EvaluationResult(2, 0, currentTime + 30 days); // extend 30 days
        }
    }
}