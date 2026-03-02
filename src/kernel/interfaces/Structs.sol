// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CapitalCall} from "../../interfaces/Structs.sol";
import {IModuleFactory} from "../../interfaces/IModuleFactory.sol";

struct DealState {
    uint256 id;
    address deal;
    IModuleFactory module;
    bool active;
    uint256 rewardsLimit;
    uint256 rewardsUnlocked;
    uint256 rewardsPaid;
    address[] evaluators;
    bytes initParams;
}

struct CapitalCallState {
    CapitalCall call;
    bool fulfilled;
}
