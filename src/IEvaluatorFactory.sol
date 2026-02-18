// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEvaluatorFactory {
    function deployEvaluator(bytes calldata config) external returns (address);
}
