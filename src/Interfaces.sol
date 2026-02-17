// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingFactory {
    function deployVoting(uint256 id, uint256 duration, address owner, address token) external returns (address);
}

interface IVoting {
    function vote(bool support) external;
    function isResolved(uint256 propId) external view returns (bool);
    function outcome(uint256 propId) external view returns (bool);
}

enum LPManagementType {
    MintMP,
    Dividend,
    CapitalCall
}

struct DealParams {
    address dealTarget;
    string description;
    uint256 fundingAmount;
    address fundingToken;
    uint256 successThreshold;
    uint256 duration;
}

struct LPMParams {
    LPManagementType typ;
    address target;
    uint256 amountOrPercent;
    address dividendToken;
    uint256 cashAmount;
}

struct CapitalCall {
    address treasuryToken;
    uint256 nonce;
    address lpRecipient;
    uint256 lpAmount;
    uint256 cashAmount;
}