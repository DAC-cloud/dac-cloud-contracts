// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEvaluator {
    function evaluateDeal(uint256 dealId, address dealAddr, address dacAddr) external returns (bool isSuccess);
}