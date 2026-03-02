// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library DACErrorsLib {

    error NotAllowed();
    error NotAuthorized();
    error NotInitialized();
    error AlreadyInitialized();

    error VoteNotPassed();

    error ProposalAlreadyExecuted();
    error InvalidDeal(address deal);
    error InvalidDealId(uint256 deal);
    error TransferFailed();

    error InvalidCapitalCall();
    error AlreadyFulfilled();

    error LegalWrapperNotSet();
    error LegalWrapperExecutionExpected();


    
    error NoVotingPower();

    error InvalidDealState(address deal);
    error InvalidTranche();
    error InsufficientTreasury();
    
    
    error NotFound();

    error InsufficientBalance();

    
    error NoStake();

    error InsufficientRewards();

    error MintBlockedByEvaluator();

    error InvalidVotingConfig();

    error DividendsNotEnabled();
    error DividendAlreadyClaimed(uint256 id, address claimer);
    error InvalidMerkleProof();

    error DealNotRecoverable();

    error ModuleNotApproved();
    error ModuleDisabled();

    error DeadlineNotPassed();
    error DealAlreadyApproved();
    error NotWhitelistedAgent();

    error NotWhitelistDeal();
    error DealIsNotApproved();
    error DealIsClosed();
    error DealIsNotClosed();
    error DealInLiquidation();
    
    error NotEnoughBalance();
    
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
    error AlreadyVoted();

    error NoFunding();
    error ConfigMismatchParams();
    error UnsupportedProposal();

    error EarlyReturnsNotAllowed();

    error CapitalWithdrawNotSupported();

    error InvalidToken();
}