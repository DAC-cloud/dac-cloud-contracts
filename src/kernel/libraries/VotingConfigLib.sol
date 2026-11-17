// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VotingConfig} from "../../interfaces/Structs.sol";
import {GovernanceLimits} from "../../interfaces/GovernanceStructs.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {MathLib} from "./MathLib.sol";

/// Shared validation of a `VotingConfig`, used by both DAC governance schemas and by deal
/// governance. The bounds are sanity checks, not policy: they reject values that can only be
/// a unit mistake or that would brick governance, and leave every economic choice open.
library VotingConfigLib {
    function validate(VotingConfig memory config) internal pure {
        // Percent thresholds: inside (0.1%, 100%]. A value below the floor is a unit mistake
        // (50 instead of 50e16) and would let dust pass or block proposals.
        require(
            config.quorumPercent >= GovernanceLimits.MIN_PERCENT && config.quorumPercent <= MathLib.SCALE,
            DACErrorsLib.InvalidVotingConfig()
        );
        require(
            config.highQuorumPercent >= GovernanceLimits.MIN_PERCENT && config.highQuorumPercent <= MathLib.SCALE,
            DACErrorsLib.InvalidVotingConfig()
        );
        // "High" is never easier to reach than the default threshold. Equality is allowed for
        // DACs that want a single threshold.
        require(config.quorumPercent <= config.highQuorumPercent, DACErrorsLib.InvalidVotingConfig());
        // Blocking is optional (zero switches it off); when set it obeys the same floor. No
        // relation to quorum is imposed: a low quorum with a larger objection threshold is a
        // legitimate optimistic setup.
        require(
            config.blockingPercent == 0
                || (config.blockingPercent >= GovernanceLimits.MIN_PERCENT && config.blockingPercent <= MathLib.SCALE),
            DACErrorsLib.InvalidVotingConfig()
        );

        require(
            config.duration > 0 && config.duration <= GovernanceLimits.MAX_DURATION, DACErrorsLib.InvalidVotingConfig()
        );
        require(
            config.executionValidityDuration > 0 && config.executionValidityDuration <= GovernanceLimits.MAX_DURATION,
            DACErrorsLib.InvalidVotingConfig()
        );

        require(config.qualification <= MathLib.SCALE / 2, DACErrorsLib.InvalidVotingConfig());
    }
}
