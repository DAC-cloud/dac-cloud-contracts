// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Interfaces.sol";

contract LPManagementProposal {
    uint256 public immutable id;
    LPManagementType public immutable typ;
    address public immutable target;
    uint256 public immutable amountOrPercent;
    address public immutable dividendToken;
    address public immutable dacEntity;
    address public immutable votingContract;
    uint256 public immutable cashAmount;

    constructor(
        uint256 _id,
        LPMParams memory params,
        address _dac,
        address _votingFactory,
        address _token
    ) {
        id = _id;
        typ = params.typ;
        target = params.target;
        amountOrPercent = params.amountOrPercent;
        dividendToken = params.dividendToken;
        dacEntity = _dac;
        cashAmount = params.cashAmount;

        votingContract = IVotingFactory(_votingFactory).deployVoting(_id, 7 days, address(this), _token);
    }

    modifier onlyDACEntity() {
        _onlyDACEntity();
        _;
    }

    function _onlyDACEntity() internal {
        require(msg.sender == dacEntity, "Only DAC");
    }
}