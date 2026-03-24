// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams} from "../../interfaces/Structs.sol";
import {Proposal} from "./Proposal.sol";

contract DACManagementProposal is Proposal {
    uint256 public id;
    address public dacEntity;

    function initialize(
        uint256 _id,
        address _dac,
        address _token,
        ProposalParams memory params,
        uint256 _votingDuration,
        uint256 _executionValidityDuration,
        uint256 _totalVotingPower,
        uint256 _votingQuorum,
        uint256 _blockingQuorum
    ) external initializer {
        __Proposal_init(
            params,
            _token,
            _votingDuration,
            _executionValidityDuration,
            _totalVotingPower,
            _votingQuorum,
            _blockingQuorum,
            false
        );

        id = _id;
        dacEntity = _dac;
    }
}
