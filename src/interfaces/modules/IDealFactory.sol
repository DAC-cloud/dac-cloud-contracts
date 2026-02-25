// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Structs.sol";

interface IDealFactory {
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address mpToken,
        address lpToken
    ) external returns (address);
}
