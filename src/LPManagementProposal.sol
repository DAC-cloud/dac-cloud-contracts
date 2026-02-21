// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

contract LPManagementProposal {
    uint256 public immutable id;
    address public immutable dacEntity;
    address public immutable votingContract;
    LPManagementType public immutable typ;
    address public immutable target;
    uint256 public immutable amount;
    bytes public data;
    
    constructor(
        uint256 _id,
        LPMParams memory params,
        address _dac,
        address _votingFactory,
        address _token,
        VotingConfig memory votingConfig
    ) {
        id = _id;
        typ = params.typ;
        dacEntity = _dac;
        target = params.target;
        amount = params.amount;
        data = params.data;

        bool highQuorum = (
            params.typ == LPManagementType.UpdateVotingConfig ||
            params.typ == LPManagementType.Dividend ||
            params.typ == LPManagementType.AddTrustedEvaluatorFactory ||
            params.typ == LPManagementType.RemoveTrustedEvaluatorFactory
        );

        bool blockingQuorum = (
            params.typ == LPManagementType.RevokeMP ||
            params.typ == LPManagementType.CapitalCall ||
            params.typ == LPManagementType.ApproveDeal ||
            params.typ == LPManagementType.ApproveTranche
        );

        votingContract = IVotingFactory(_votingFactory).deployVoting(
            _id, 
            votingConfig.defaultDuration, 
            _token,
            highQuorum ? votingConfig.highQuorumPercent : votingConfig.quorumPercent,
            blockingQuorum ? votingConfig.blockingPercent : 0
        );
    }

    function getDividendToken() external view returns (address) {
        require(typ == LPManagementType.Dividend, "Not Dividend type");
        return abi.decode(data, (address));
    }

    function getCashAmount() external view returns (uint256) {
        require(
            typ == LPManagementType.Dividend ||
            typ == LPManagementType.CapitalCall,
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
            typ == LPManagementType.AddTrustedEvaluatorFactory ||
            typ == LPManagementType.RemoveTrustedEvaluatorFactory,
            "Not applicable type"
        );
        return abi.decode(data, (address));
    }

    function getTrancheId() external view returns (uint256) {
        require(
            typ == LPManagementType.ApproveDeal ||
            typ == LPManagementType.ApproveTranche,
            "Not applicable type"
        );
        (uint256 trancheId,) = abi.decode(data, (uint256, uint256));
        return trancheId;
    }

    function getDealId() external view returns (uint256) {
        require(
            typ == LPManagementType.ApproveDeal ||
            typ == LPManagementType.ApproveTranche,
            "Not applicable type"
        );
        (, uint256 dealId) = abi.decode(data, (uint256, uint256));
        return dealId;
    }

    function getMPAmount() external view returns (uint256) {
        require(
            typ == LPManagementType.MintMP || 
            typ == LPManagementType.RevokeMP, 
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