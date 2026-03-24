// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotes {
    /**
     * @dev Delegates votes from the sender to `delegatee`.
     */
    function delegate(address delegatee) external;

    function delegates(address account) external view returns (address);
    function getVotes(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}
