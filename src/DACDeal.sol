// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MPToken.sol";
import "./IDeal.sol";
import "./Interfaces.sol";
import "./LPToken.sol";
import "./IDACEntity.sol";
import "./Deal.sol";

contract DACDeal is Deal {
    uint256 private _childLPAmount;
    mapping(uint256 => address) public childProposalVotings;

    // Events
    event ChildProposalVotingCreated(uint256 indexed childProposalId, address voting);
    event ChildProposalVoted(uint256 indexed childProposalId, bool support);

    constructor(
        uint256 _id,
        address _dac,
        address _child,
        address _mpToken,
        address _lpToken,
        address _votingFactory,
        address _proposer,
        bool _isWhitelistOnly
    ) Deal(_id, _dac, _child, _mpToken, _lpToken, _votingFactory, _proposer, _isWhitelistOnly) {}

    function initialize(
        DealParams calldata params,
        VotingConfig calldata votingConfig
    ) public override {
        super.initialize(params, votingConfig);

        _childLPAmount = params.managedEquity;
    }

    function onApproved() public override onlyDACEntity {
        super.onApproved();

        CapitalCall memory call = CapitalCall({
            treasuryToken: super.fundingToken(),
            nonce: id,
            lpRecipient: address(this),
            lpAmount: _childLPAmount,
            cashAmount: super.fundingAmount()
        });

        IDACEntity(managedEntity).fulfillCapitalCall(call);
        
        emit DealActivated(id);
    }

    function createChildProposalVoting(uint256 childProposalId) external onlyStakedMPHolder {
        require(childProposalVotings[childProposalId] == address(0), "Voting already exists");
        
        address voting = IVotingFactory(votingFactoryAddr).deployVoting(
            childProposalId, 
            super.votingConfig().defaultDuration, 
            address(this), 
            address(this), 
            super.votingConfig().quorumPercent
        );
        childProposalVotings[childProposalId] = voting;
        
        emit ChildProposalVotingCreated(childProposalId, voting);
    }

    function resolveChildProposalVote(uint256 childProposalId) external onlyStakedMPHolder {
        address voting = childProposalVotings[childProposalId];
        require(voting != address(0), "No voting for this proposal");
        require(IVoting(voting).isResolved(childProposalId), "Voting not resolved");
        
        bool support = IVoting(voting).outcome(childProposalId);
        address childVoting = IDACEntity(managedEntity).getProposalVoting(childProposalId);
        IVoting(childVoting).vote(support);
        
        emit ChildProposalVoted(childProposalId, support);
    }
}