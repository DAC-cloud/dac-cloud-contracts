// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams} from "../../interfaces/Structs.sol";
import {Proposal} from "./Proposal.sol";

contract DealManagementProposal is Proposal {
    uint256 public id;
    address public dacEntity;
    address public deal;
    
    function initialize(
        uint256 _id,
        bytes memory addresses,
        bytes memory variables,
        ProposalParams memory params
    ) external initializer {
        address _token;
        address vetoRightOwner;

        (dacEntity, deal, _token, vetoRightOwner) = abi.decode(
            addresses,
            (address, address, address, address)
        );

        (uint256 _votingDuration, uint256 _totalVotingPower, uint256 _votingQuorum, uint256 _blockingQuorum) = abi.decode(
            variables,
            (uint256, uint256, uint256, uint256)
        );

        __Proposal_init(
            params, 
            _token, 
            _votingDuration, 
            _totalVotingPower,
            _votingQuorum, 
            _blockingQuorum, 
            vetoRightOwner
        );

        id = _id;
    }
}