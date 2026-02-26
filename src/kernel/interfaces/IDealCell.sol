// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Structs.sol";
import "../governance/DealManagementProposal.sol";

interface IDealCell {
    function claimMainToken() external;
    
    function requestTranche(
        DealManagementProposal prop
    ) external;

    function stakeToken() external view returns (address);
    function onAgentTokenStaked(address staker, uint256 amount) external;
    function unstake() external;
    
    function withdrawCapital() external;
    
    function fundingToken(uint256 trancheId) external view returns (address);
    function fundingAmount(uint256 trancheId) external view returns (uint256);
    function fundingTokens() external view returns (address[] memory);

    function getStakedAgentTotal() external view returns (uint256);
    function getReturnedCapital(address token) external view returns (uint256);
    function getInvestedCapital(address token) external view returns (uint256);
    function getMainRewardsLimit() external view returns (uint256);
    
    function isValidDeal() external pure returns (bool);
    function isApproved() external view returns (bool);
    function isClosed() external view returns (bool);
    function approveDeadline() external view returns (uint256);
    function dealDeadline() external view returns (uint256);

    function toggleWhitelist(bool whitelistOnly) external;
    function addStake(address staker, uint256 amount) external;
}