// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";
import "./Proposal.sol";

contract StakedMPProposal is Proposal {
    uint256 public immutable id;
    address public immutable deal;
    StakedMPManagementType public immutable typ;
    address public immutable target;
    uint256 public immutable targetId;
    bytes public data;
    
    constructor(
        uint256 _id,
        StakedMPParams memory params,
        address _deal,
        uint256 _votingDuration, 
        uint256 _votingQuorum, 
        uint256 _blockingQuorum
    ) Proposal(_deal, _votingDuration, _votingQuorum, _blockingQuorum) {
        id = _id;
        typ = params.typ;
        deal = _deal;
        target = params.target;
        targetId = params.id;
        data = params.data;
    }

    function getToggleValue() external view returns (bool toggle) {
        require(
            (
                typ == StakedMPManagementType.ToggleEarlyReturns ||
                typ == StakedMPManagementType.ChildLPProposalVoting
            ),
            "Not applicable type"
        );
        (toggle) = abi.decode(data, (bool));
    }

    function getLPMParams() external view returns (LPMParams memory params) {
        require(
            (
                typ == StakedMPManagementType.CreateChildLPProposal
            ),
            "Not applicable type"
        );
        (params) = abi.decode(data, (LPMParams));
    }

    function getApproveCallData() external view returns (address spender, uint160 amount, uint48 expiration) {
        require(
            (
                typ == StakedMPManagementType.ApprovePermit2Spend
            ),
            "Not applicable type"
        );
        (spender, amount, expiration) = abi.decode(data, (address, uint160, uint48));
    }

    function getApproveAgentCallData() external view returns (address token, address counterparty, uint160 amount) {
        require(
            (
                typ == StakedMPManagementType.ApproveAgentSpend ||
                typ == StakedMPManagementType.AssignClaimer
            ),
            "Not applicable type"
        );
        (token, counterparty, amount) = abi.decode(data, (address, address, uint160));
    }

    function getVotingConfiguration() external view returns (VotingConfig memory) {
        require(
            typ == StakedMPManagementType.UpdateVotingConfig,
            "Not applicable type"
        );
        (VotingConfig memory configuration) = abi.decode(data, (VotingConfig));
        return configuration;
    }

    function getAmount() external view returns (uint256 amount) {
        require(
            (
                typ == StakedMPManagementType.ReturnCapitalToDAC ||
                typ == StakedMPManagementType.AddStake
            ),
            "Not applicable type"
        );
        (amount) = abi.decode(data, (uint256));
    }

    function getFundingAmount() external view returns (uint256 amount) {
        require(
            (
                typ == StakedMPManagementType.RequestTranche ||
                typ == StakedMPManagementType.ReinvestProfits
            ),
            "Not applicable type"
        );
        (amount,) = abi.decode(data, (uint256, bytes32));
    }

    function getFundingCalldata() external view returns (bytes32 calldataHash) {
        require(
            (
                typ == StakedMPManagementType.RequestTranche ||
                typ == StakedMPManagementType.ReinvestProfits
            ),
            "Not applicable type"
        );
        (,calldataHash) = abi.decode(data, (uint256, bytes32));
    }

    modifier onlyDealEntity() {
        _onlyDealEntity();
        _;
    }

    function _onlyDealEntity() internal view {
        require(msg.sender == deal, "Only Deal");
    }
}