// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvaluationResult} from "./Structs.sol";

interface IEvaluator {
    function permitMint(address deal, address to, uint256 amount) external returns (bool permit);
    function evaluateDeal(uint256 dealId, address dealAddr, address deal, address dacAddr) external returns (EvaluationResult memory);
}