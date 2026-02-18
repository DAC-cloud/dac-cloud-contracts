// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IEvaluator.sol";

contract BasicEvaluator is IEvaluator {
    function evaluateDeal(uint256, address, address) external pure returns (bool) {
        // Placeholder – always success for now
        // Later: call oracles, read deal metrics, successThreshold checks, etc.
        return true;
    }
}