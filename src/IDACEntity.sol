// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDACEntity {
    struct CapitalCall {
        address treasuryToken;
        uint256 nonce;
        address lpRecipient;
        uint256 lpAmount;
        uint256 cashAmount;
    }

    function fulfillCapitalCall(CapitalCall calldata call) external returns (bool);
    function voteOnProposal(uint256 proposalId, bool support) external;
    function getQuorumPercent() external view returns (uint256);
    function getTreasuryBalance(address token) external view returns (uint256);
    function getLPToken() external view returns (address);

    struct Config {
        uint256 quorumPercent;
        address lpToken;
        address mpToken;
        address votingFactory;
    }
}