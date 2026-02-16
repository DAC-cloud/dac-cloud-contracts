// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

contract LPManagementProposal {
    uint256 public id;
    LPManagementType public typ;
    address public target;
    uint256 public amountOrPercent;
    address public dividendToken;
    address public dacEntity;
    address private _votingContract;

    constructor(
        uint256 _id,
        LPManagementType _typ,
        address _target,
        uint256 _amt,
        address _divToken,
        address _dac,
        address _votingFactory,
        address _token
    ) {
        id = _id;
        typ = _typ;
        target = _target;
        amountOrPercent = _amt;
        dividendToken = _divToken;
        dacEntity = _dac;
        _votingContract = IVotingFactory(_votingFactory).deployVoting(_id, 7 days, address(this), _token);
    }

    function amount() external view returns (uint256) {
        return amountOrPercent;
    }

    function percent() external view returns (uint256) {
        return amountOrPercent;
    }

    function votingContract() external view returns (address) {
        return _votingContract;
    }

    function execute() external onlyDACEntity {
        // Handled in DACEntity
    }

    modifier onlyDACEntity() {
        require(msg.sender == dacEntity, "Only DAC");
        _;
    }

    event LPMProposalExecuted(uint256 indexed id, LPManagementType typ);
}