// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams} from "./Structs.sol";

interface IDealManager {
    function deals(uint256 id) external view returns (address);

    function createDealProposal(DealParams calldata params) external returns (uint256 id, address dealCell, address dealAddr, address evaluatorAddr);

    function isRecoverable(uint256 id) external view returns (bool);

    function totalReleasedVotable() external returns (uint256);
}