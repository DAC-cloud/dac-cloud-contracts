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
    uint256 timestamp;              // hard deadline for the milestone
    uint256 duration;               // if zero, milestone is fixed in time, if > 0, milestone is repeating (until triggered by returns)
    uint256 expectedReturnPercent;  // cumulative % or amount of funding expected back
    uint256 rewardPercentage;       // unlock % (calculated always of the total remaining rewards)
    uint256 penalty;                // slash % applied
    bool penaltyProRata;            // if false - slash full penalty
}

struct RevenueStreamConfig {
    address token;
    uint256 duration;               // e.g., weekly = 7 days
    uint256 expectedMinAmount;      // minimum recurring amount
    uint256 rewardPercentage;       // small unlock per cycle (1–3%)
    uint256 penaltyPercentage;      // per missed cycle
    uint256 tolerancePercentage;    // e.g., 90% = near miss
    bytes curveData;                // encoded polynomial for non-linear rewards
}
