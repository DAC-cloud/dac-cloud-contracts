// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Tranche} from "./Structs.sol";
import {IDeal} from "./IDeal.sol";

interface IDealCell {
    function name() external view returns (string memory);
    function description() external view returns (string memory);

    function deal() external view returns (IDeal);
    function manager() external view returns (address);

    function startTime() external view returns (uint256);

    function stakeToken() external view returns (address);

    function invite(address invitee, bool grantInviteRight) external;

    function claimMainToken(uint256 evaluatorId) external;
    function unstake() external;
    
    function fundingTranche(uint256 trancheId) external view returns (Tranche memory tranche);
    function fundingTokens() external view returns (address[] memory);

    function getReturnedCapital(address token) external view returns (uint256);
    function getInvestedCapital(address token) external view returns (uint256);
    function getMainRewardsLimit() external view returns (uint256);
    function rewardsConvertedPct() external view returns (uint256);
    
    function allowEarlyReturns() external view returns (bool);
    function allowDACVeto() external view returns (bool);

    function isValidDeal() external pure returns (bool);
    function isApproved() external view returns (bool);
    function isClosed() external view returns (bool);

    function approveDeadline() external view returns (uint256);
    function evaluationDeadline() external view returns (uint256);
    function dealDeadline() external view returns (uint256);
}
