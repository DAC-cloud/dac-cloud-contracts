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
    address token;                  // token for accounting purposes
    uint256 timestamp;              // hard deadline for the milestone
    uint256 expectedReturnPercent;  // cumulative % or amount of funding expected back
    uint256 rewardPercentage;       // unlock % (calculated always of the total remaining rewards)
    uint256 penalty;                // slash % applied
}

struct RevenueSchedule {
    address token;                      // revenue accounting token
    uint256 duration;                   // period length (e.g. 30 days)
    uint8 revenueProjectionMode;        // 0 - fixed expected revenue, 1 - number of cycles to return investments
    uint256 revenueProjection;          // revenue projection
    int256[] curveCoeffs;               // reward curve, polynomial coeffs (a + b*x + c*x² + d*x³)
    int256[] requirementCurveCoeffs;    // growing target curve (cycle → expected revenue)
    uint256 maxCycleUnlockPercent;      // minimum unlock even if below target (forgiving)
    uint256 minCycleRevenuePercent;     // minimal revenue percent before counting as miss
    uint256 graceCycles;                // consecutive misses before slashing starts
    uint256 penaltyPerMiss;             // small penalty % per missed cycle
    uint256 evaluationStart;            // timestamp for starting evaluation, if 0 - starting at deal start
}
