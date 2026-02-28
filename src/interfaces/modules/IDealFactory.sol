// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "../Structs.sol";

interface IDealFactory {
    function deployDeal(
        uint256 id,
        address dealCell,
        DealParams calldata params,
        address dac,
        address agentToken,
        address mainToken
    ) external returns (address);
}
