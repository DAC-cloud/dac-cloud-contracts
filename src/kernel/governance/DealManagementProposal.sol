// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams} from "../../interfaces/Structs.sol";
import {Proposal} from "./Proposal.sol";
import {IVoting} from "../../interfaces/IVoting.sol";
import {IExecutableProposal} from "../../interfaces/IExecutableProposal.sol";
import {IDealChallengeableProposal} from "../../interfaces/IDealChallengeableProposal.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

contract DealManagementProposal is Proposal, IDealChallengeableProposal {
    uint256 public id;
    address public dacEntity;
    address public deal;

    bool private challengeable;
    address public dacChallengeProposal;

    function initialize(
        uint256 _id,
        bytes memory addresses,
        bytes memory variables,
        ProposalParams memory params
    ) external initializer {
        address _executor;
        address _token;
        uint256 _votingDuration;
        uint256 _executionValidityDuration;
        uint256 _totalVotingPower;
        uint256 _votingQuorum;
        uint256 _blockingQuorum;

        // `_executor` is packed into `addresses` to keep the parameter list
        // within stack-depth limits (the bytes packing was already used for
        // the same reason on the rest of the address-shaped inputs).
        (_executor, dacEntity, deal, _token, challengeable) = abi.decode(
            addresses,
            (address, address, address, address, bool)
        );

        (_votingDuration, _executionValidityDuration, _totalVotingPower, _votingQuorum, _blockingQuorum) = abi.decode(
            variables,
            (uint256, uint256, uint256, uint256, uint256)
        );

        __Proposal_init(
            params,
            _executor,
            _token,
            _votingDuration,
            _executionValidityDuration,
            _totalVotingPower,
            _votingQuorum,
            _blockingQuorum,
            challengeable
        );

        id = _id;
    }

    function registerDACChallenge(address challengeProposal) external {
        require(msg.sender == dacEntity, DACErrorsLib.NotAuthorized());
        require(challengeable, DACErrorsLib.NotAllowed());
        require(challengeProposal != address(0), DACErrorsLib.NotAllowed());
        require(dacChallengeProposal == address(0), DACErrorsLib.ProposalAlreadyChallenged());
        require(!this.isExecuted(), DACErrorsLib.ProposalAlreadyExecuted());
        require(!this.isExecutionExpired(), DACErrorsLib.ProposalNotExecutable());

        dacChallengeProposal = challengeProposal;

        emit DACEventsLib.DealProposalChallenged(deal, id, challengeProposal);
    }

    function isChallengeable() external view returns (bool enabled) {
        enabled = challengeable;
    }

    function _executionAvailableFrom() internal override returns (uint256 availableFrom) {
        availableFrom = resolutionTime;

        if (dacChallengeProposal == address(0)) {
            return availableFrom;
        }

        IExecutableProposal challenge = IExecutableProposal(dacChallengeProposal);

        if (!IVoting(dacChallengeProposal).isResolved()) {
            return type(uint256).max;
        }

        if (!IVoting(dacChallengeProposal).outcome()) {
            uint256 releaseAt = challenge.resolutionTime();
            return releaseAt > availableFrom ? releaseAt : availableFrom;
        }

        if (challenge.isExecuted()) {
            return type(uint256).max;
        }

        if (!challenge.isExecutionExpired()) {
            return type(uint256).max;
        }

        uint256 expiryRelease = challenge.executionDeadline();
        return expiryRelease > availableFrom ? expiryRelease : availableFrom;
    }

    function _isExecutableNow() internal override returns (bool executable) {
        if (dacChallengeProposal != address(0)) {
            IExecutableProposal challenge = IExecutableProposal(dacChallengeProposal);

            if (IVoting(dacChallengeProposal).isResolved() && IVoting(dacChallengeProposal).outcome() && challenge.isExecuted()) {
                return false;
            }
        }

        executable = super._isExecutableNow();
    }
}
