// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IExecutableProposal} from "./IExecutableProposal.sol";

interface IDealChallengeableProposal is IExecutableProposal {
    function registerDACChallenge(address challengeProposal) external;
    function isChallengeable() external view returns (bool);
    function dacChallengeProposal() external view returns (address);
}
