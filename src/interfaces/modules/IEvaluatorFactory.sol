// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Structs.sol";

interface IEvaluatorFactory {
    function deployEvaluator(
        address dac, 
        uint256 id, 
        DealParams calldata deal
    ) external returns (address);
}
