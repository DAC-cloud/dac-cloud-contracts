// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library DACErrorsLib {

    error NotAllowed();
    error NotAuthorized();
    error NotInitialized();
    error AlreadyInitialized();

    error NotFound();

    error InvalidVotingConfig();

    error NoVotingPower();
    error ControlledAddressLimitReached();
    error ControlledAddressNotContract();
    error ControlledAddressHasVotingPower();
    error VoteNotPassed();
    error ProposalNotExecutable();
    error ProposalAlreadyChallenged();

    error ProposalAlreadyExecuted();

    error MaxSupplyExceeded();

    error NotTransferable();

    error TransferFailed();
    error InsufficientBalance();
    error NotEnoughBalance();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error LegalWrapperNotSet();
    error LegalWrapperExecutionExpected();

    error ModuleNotApproved();
    error ModuleDisabled();
    error GovernanceFactoryNotAccepted();

    error InvalidDealAddress();
    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);

    error InvalidDealState(address deal);
    error InvalidTranche();
    error InsufficientTreasury();
        
    error NoStake();

    error InsufficientRewards();

    error MintBlockedByEvaluator();

    error DividendsNotEnabled();
    error DividendAlreadyClaimed(uint256 id, address claimer);
    error InvalidMerkleProof();
    error DividendPayoutExceeded();

    error DealNotRecoverable();

    error DeadlineNotPassed();
    error DealAlreadyApproved();
    error NotWhitelistedAgent();

    error NotWhitelistDeal();
    error DealIsNotApproved();
    error DealIsClosed();
    error DealIsNotClosed();
    error DealInLiquidation();
        
    error ProposalNotSupported();
    error InvalidProposal();
    error AlreadyExecuted();

    error MessageNotAccepted();

    error NotStakedAgent();

    error TrancheNotExists();
    error TrancheAlreadySettled();

    error NoClaimableRewards();

    error NotResolved();
    error VetoNotEnabled();
    error VotingEnded();
    // Voting on a native or deal proposal opens the second after its creation
    error VotingNotStarted();
    error AlreadyVoted();

    error NoFunding();
    error ConfigMismatchParams();
    error UnsupportedProposal();

    error EarlyReturnsNotAllowed();
    error PermitExpirationTooShort();

    error CapitalWithdrawNotSupported();

    error InvalidToken();

    error AgentsLimitReached();
    error InsufficientStake();
    error EvaluatorNotCompatible();

    // Vote locks: the account does not hold the votes a lock requires
    error VotesLocked();

    error CapitalCallExpired();

    // Staking
    error ZeroStake();
    error HoldersLimitReached();

    error DividendClaimWindowClosed();
    error DividendClaimWindowOpen();

    // Not enough gas forwarded to guarantee a kernel-to-module hook its stipend
    error InsufficientGas();
}
