// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

/// Vote locks for a DAC's governance token.
///
/// A lock pins an amount of *voting power* on an account until a timestamp: while it is
/// live, nothing may bring that account's delegated votes below the locked amount. That
/// covers a transfer, an unwrap or burn, and a re-delegation, by the account itself or by
/// anyone who delegated to it. Whoever lends votes to a delegate shares its locks.
///
/// Only the DAC's governance schema can lock, and only on an account's own governance act:
/// creating a proposal (the qualification amount, for the life of the proposal) or, where
/// the DAC configures it, casting a vote (a share of the vote weight, for a set period).
/// Capital used to govern stays exposed to the outcome instead of leaving in the next block.
abstract contract VoteLock {
    struct Lock {
        uint208 amount;
        uint48 until;
    }

    // No lock outlives this, whatever the schema asks for: the longest scheduled path of a
    // proposal is three configured durations of at most a year each.
    uint256 internal constant MAX_LOCK_DURATION = 3 * 365 days;

    mapping(address => Lock) private _voteLocks;

    /// The only address allowed to lock: the DAC's governance schema.
    function _voteLockAuthority() internal view virtual returns (address);

    /// Current delegated votes of `account`.
    function _currentVotes(address account) internal view virtual returns (uint256);

    /// Locks at least `amount` votes of `account` until at least `until`. Locks merge
    /// conservatively: the larger amount and the later expiry win, so an account is never
    /// under-locked. Reverts when the account does not hold the votes right now.
    function lockVotes(address account, uint256 amount, uint256 until) external {
        require(msg.sender == _voteLockAuthority(), DACErrorsLib.NotAuthorized());
        require(until <= block.timestamp + MAX_LOCK_DURATION, DACErrorsLib.NotAllowed());
        require(amount <= type(uint208).max, DACErrorsLib.NotAllowed());

        Lock memory lock = _voteLocks[account];
        if (block.timestamp > lock.until) {
            lock.amount = 0;
        }
        if (amount > lock.amount) {
            // casting to 'uint208' is safe: checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            lock.amount = uint208(amount);
        }
        if (until > lock.until) {
            // casting to 'uint48' is safe: bounded by MAX_LOCK_DURATION above
            // forge-lint: disable-next-line(unsafe-typecast)
            lock.until = uint48(until);
        }

        require(_currentVotes(account) >= lock.amount, DACErrorsLib.VotesLocked());
        _voteLocks[account] = lock;

        emit DACEventsLib.VotesLocked(account, lock.amount, lock.until);
    }

    /// Votes of `account` that are locked right now, and until when.
    function lockedVotes(address account) public view returns (uint256 amount, uint256 until) {
        Lock memory lock = _voteLocks[account];
        if (block.timestamp > lock.until) {
            return (0, lock.until);
        }
        return (lock.amount, lock.until);
    }

    /// Call after anything that may have lowered the votes of `account`.
    function _enforceVoteLock(address account) internal view {
        if (account == address(0)) return;

        Lock memory lock = _voteLocks[account];
        if (lock.amount != 0 && block.timestamp <= lock.until) {
            require(_currentVotes(account) >= lock.amount, DACErrorsLib.VotesLocked());
        }
    }
}
