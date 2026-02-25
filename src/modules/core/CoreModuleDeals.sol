// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICoreDeals {
    function createDACDeal() external pure returns (bytes4);

    function createPermit2TreasuryDeal() external pure returns (bytes4);
}

interface ICoreEvaluators {
    function createBasicEvaluator() external pure returns (bytes4);
}

library CoreDealType {
    bytes4 public constant DAC_DEAL         = ICoreDeals.createDACDeal.selector;
    bytes4 public constant PERMIT2_TREASURY = ICoreDeals.createPermit2TreasuryDeal.selector;
}

library CoreEvaluatorType {
    bytes4 public constant BASIC_REVENUE_MILESTONES = ICoreEvaluators.createBasicEvaluator.selector;
}
