// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICoreDeals {
    function createDACDeal() external pure returns (bytes4);
    function createPermit2TreasuryDeal() external pure returns (bytes4);
}

interface ICoreEvaluators {
    function createMilestoneEvaluator() external pure returns (bytes4);
    function createRevenueEvaluator() external pure returns (bytes4);
}

library CoreDealType {
    bytes4 public constant DAC_DEAL         = ICoreDeals.createDACDeal.selector;
    bytes4 public constant PERMIT2_TREASURY = ICoreDeals.createPermit2TreasuryDeal.selector;
}

library CoreEvaluatorType {
    bytes4 public constant MILESTONES_EVALUATOR = ICoreEvaluators.createMilestoneEvaluator.selector;
    bytes4 public constant REVENUE_EVALUATOR    = ICoreEvaluators.createRevenueEvaluator.selector;
}
