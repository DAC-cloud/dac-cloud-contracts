// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvaluationResult} from "../../../interfaces/Structs.sol";
import {IEvaluator} from "../../../interfaces/IEvaluator.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {Milestone} from "../interfaces/Structs.sol";

contract BasicEvaluator is IEvaluator {
    address public immutable dac;
    uint256 public immutable deal;
    address public immutable cell;
    Milestone[] public schedule;

    constructor(address _dac, uint256 _deal, address _cell, Milestone[] memory _schedule) {
        dac = _dac;
        deal = _deal;
        cell = _cell;
        for (uint256 i = 0; i < _schedule.length; i++) {
            schedule.push(_schedule[i]);
        }
    }

    function permitMint(address, address, uint256) external pure returns (bool permit) {
        // Basic evaluator will not do any additional authorization for unlocking LP rewards.
        // However it would be a good practice for external modules to allow such a protection.

        // With permitMint implemented evaluator can become an oracle for last-resort protection between
        //  vulnerabilities in the particular Deal contract.
        
        // Basic logic for evaluator - revert any mintLP call, until someone presses the button on the web
        //  and signs with EOA, then there is a 12 hours window, and if no other EOA objects and provide
        //  to an AI agent reasonable claims about a hack in a Deal - evaluator approves the single mint

        return true;
    }

    function evaluateDeal(uint256, address dealCell, address, address) external view returns (EvaluationResult[] memory evaluations) {
        uint256 returned = 0; // IDealCell(dealAddr).getReturnedCapital(token);
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
        
        evaluations = new EvaluationResult[](1);
        if (returned >= expected) {
            evaluations[0] = EvaluationResult(1, 100, 0); // convert 100%
        } else if (currentTime > IDealCell(dealCell).dealDeadline()) {
            evaluations[0] = EvaluationResult(0, 100, 0); // slash 100%
        } else {
            evaluations[0] = EvaluationResult(2, 0, currentTime + 30 days); // extend 30 days
        }
    }
}