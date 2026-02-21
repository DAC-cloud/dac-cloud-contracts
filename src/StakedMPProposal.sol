// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

contract StakedMPProposal {
    uint256 public immutable id;
    address public immutable deal;
    address public immutable votingContract;
    StakedMPManagementType public immutable typ;
    address public immutable target;
    uint256 public immutable targetId;
    bytes public data;
    
    constructor(
        uint256 _id,
        StakedMPParams memory params,
        address _deal,
        address _votingFactory,
        address _token,
        VotingConfig memory votingConfig
    ) {
        id = _id;
        typ = params.typ;
        deal = _deal;
        target = params.target;
        targetId = params.id;
        data = params.data;

        bool highQuorum = (
            params.typ == StakedMPManagementType.UpdateVotingConfig ||
            params.typ == StakedMPManagementType.RequestTranche ||
            params.typ == StakedMPManagementType.AddStake ||
            params.typ == StakedMPManagementType.ToggleEarlyReturns ||
            params.typ == StakedMPManagementType.ToggleWhitelist
        );

        bool blockingQuorum = (
            params.typ == StakedMPManagementType.ChildLPProposalVoting ||
            params.typ == StakedMPManagementType.ApprovePermit2Spend
        );

        votingContract = IVotingFactory(_votingFactory).deployVoting(
            _id, 
            votingConfig.defaultDuration, 
            _token,
            highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
            blockingQuorum ? votingConfig.blockingPercent : 0
        );
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

    function getCalldataHash() external view returns (bytes32 calldataHash) {
        require(
            (
                typ == StakedMPManagementType.ApprovePermit2Spend
            ),
            "Not applicable type"
        );
        (calldataHash) = abi.decode(data, (bytes32));
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
                typ == StakedMPManagementType.ReturnCapitalToDAC
            ),
            "Not applicable type"
        );
        (amount) = abi.decode(data, (uint256));
    }

    function getFundingAmount() external view returns (uint256 amount) {
        require(
            (
                typ == StakedMPManagementType.RequestTranche
            ),
            "Not applicable type"
        );
        (amount,) = abi.decode(data, (uint256, bytes32));
    }

    function getFundingCalldata() external view returns (bytes32 calldataHash) {
        require(
            (
                typ == StakedMPManagementType.RequestTranche
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