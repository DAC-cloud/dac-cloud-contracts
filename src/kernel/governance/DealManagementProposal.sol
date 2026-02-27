// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams} from "../../interfaces/Structs.sol";
import {Proposal} from "./Proposal.sol";

contract DealManagementProposal is Proposal {
    uint256 public immutable id;
    address public immutable dacEntity;
    address public immutable deal;
    
    constructor(
        uint256 _id,
        address _dac,
        address _deal,
        address _token,
        ProposalParams memory params,
        uint256 _votingDuration, 
        uint256 _votingQuorum, 
        uint256 _blockingQuorum,
        address vetoRightOwner
    ) Proposal(params, _token, _votingDuration, _votingQuorum, _blockingQuorum, vetoRightOwner) {
        id = _id;
        dacEntity = _dac;
        deal = _deal;
    }
}