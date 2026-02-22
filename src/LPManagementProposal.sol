// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";
import "./Proposal.sol";

contract LPManagementProposal is Proposal {
    uint256 public immutable id;
    address public immutable dacEntity;
    LPManagementType public immutable typ;
    address public immutable target;
    uint256 public immutable amount;
    bytes public data;
    
    constructor(
        uint256 _id,
        address _dac,
        address _token,
        LPMParams memory params,
        uint256 _votingDuration, 
        uint256 _votingQuorum, 
        uint256 _blockingQuorum
    ) Proposal(_token, _votingDuration, _votingQuorum, _blockingQuorum) {
        id = _id;
        typ = params.typ;
        dacEntity = _dac;
        target = params.target;
        amount = params.amount;
        data = params.data;
    }

    function getDividendToken() external view returns (address) {
        require(typ == LPManagementType.Dividend, "Not Dividend type");
        return abi.decode(data, (address));
    }

    function getCashAmount() external view returns (uint256) {
        require(
            (
                typ == LPManagementType.Dividend ||
                typ == LPManagementType.CapitalCall
            ),
            "Not applicable type"
        );
        (, uint256 cash) = abi.decode(data, (address, uint256));
        return cash;
    }

    function getMerkleRoot() external view returns (bytes32) {
        require(
            typ == LPManagementType.Dividend,
            "Not applicable type"
        );
        (, , bytes32 merkleRoot) = abi.decode(data, (address, uint256, bytes32));
        return merkleRoot;
    }

    function getFactoryAddress() external view returns (address) {
        require(
            (
                typ == LPManagementType.AddTrustedEvaluatorFactory ||
                typ == LPManagementType.RemoveTrustedEvaluatorFactory
            ),
            "Not applicable type"
        );
        return abi.decode(data, (address));
    }

    function getTrancheId() external view returns (uint256) {
        require(
            (
                typ == LPManagementType.ApproveDeal ||
                typ == LPManagementType.ApproveTranche
            ),
            "Not applicable type"
        );
        (uint256 trancheId,) = abi.decode(data, (uint256, uint256));
        return trancheId;
    }

    function getVotingConfiguration() external view returns (VotingConfig memory) {
        require(
            typ == LPManagementType.UpdateVotingConfig,
            "Not applicable type"
        );
        (VotingConfig memory configuration) = abi.decode(data, (VotingConfig));
        return configuration;
    }

    function getDealId() external view returns (uint256) {
        require(
            (
                typ == LPManagementType.ApproveDeal ||
                typ == LPManagementType.ApproveTranche
            ),
            "Not applicable type"
        );
        (, uint256 dealId) = abi.decode(data, (uint256, uint256));
        return dealId;
    }

    function getRecoveredDealId() external view returns (uint256) {
        require(
            typ == LPManagementType.RecoverDeal,
            "Not applicable type"
        );
        (uint256 dealId) = abi.decode(data, (uint256));
        return dealId;
    }

    function getMPAmount() external view returns (uint256) {
        require(
            (
                typ == LPManagementType.MintMP || 
                typ == LPManagementType.RevokeMP ||
                typ == LPManagementType.RecoverDeal
            ), 
            "Not *MP type"
        );
        return amount; // already stored directly
    }

    function getLPAmount() external view returns (uint256) {
        require(typ == LPManagementType.CapitalCall, "Not CapitalCall type");
        return amount; // already stored directly
    }

    modifier onlyDACEntity() {
        _onlyDACEntity();
        _;
    }

    function _onlyDACEntity() internal view {
        require(msg.sender == dacEntity, "Only DAC");
    }
}