// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IModuleFactory.sol";

struct DealState {
    uint256 id;
    address deal;
    IModuleFactory module;
    uint256 rewardsLimit;
    address evaluator;
}

struct CapitalCallState {
    CapitalCall call;
    bool fulfilled;
}

struct Tranche {
    address token;
    uint256 amount;
    bool settled;
}
