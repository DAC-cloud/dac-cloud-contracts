// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/Structs.sol";
import "./Proposal.sol";

contract LPManagementProposal is Proposal {
    uint256 public immutable id;
    address public immutable dacEntity;
    
    constructor(
        uint256 _id,
        address _dac,
        address _token,
        ProposalParams memory params,
        uint256 _votingDuration, 
        uint256 _votingQuorum, 
        uint256 _blockingQuorum
    ) Proposal(params, _token, _votingDuration, _votingQuorum, _blockingQuorum) {
        id = _id;
        dacEntity = _dac;
    }
}