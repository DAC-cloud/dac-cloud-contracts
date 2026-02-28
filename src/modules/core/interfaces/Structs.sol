// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct DACDealConfig {
    uint256 managedEquity;          // only for DAC based Deals (investment into child DAC LP)
    uint256 capitalCallId;          // only for DAC based Deals
    bytes config;
}

struct TreasurySpendAllowance {
    uint160 totalAmount;
    uint160 singleTxAmount;
    uint256 clockLimit;
    uint256 duration;
}

struct Milestone {
    bytes32 milestoneType;          // opaque bytes for milestone type, and byte-masked functionality encoding
    address token;                  // token for accounting purposes
    uint256 timestamp;
    uint256 expectedReturnPercent;  // cumulative % or amount of funding expected back
    uint256 rewardPercentage;
    uint256 penalty;                // slash % applied
}
