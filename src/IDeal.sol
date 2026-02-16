// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeal {
    function isValidDeal() external view returns (bool);
    function onMPStaked(address staker, uint256 amount) external;
    function votingContract() external view returns (address);
    function fundingToken() external view returns (address);
    function fundingAmount() external view returns (uint256);
    function onApproved() external;
    function transformStakes() external;
    function slashStakes(uint256 slashPercent) external;
    function childDAC() external view returns (address);
    function getStakedMPTotal() external view returns (uint256);
}
