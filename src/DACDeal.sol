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
    
    // Events
    event ChildLPVoteCreated(uint256 indexed childProposalId, uint256 proposalId);
    event ChildLPVoteCasted(uint256 indexed childProposalId, bool support);
    event ChildDealVoteCasted(uint256 indexed childDealId, bool support);

    constructor(
        uint256 _id,
        address _governanceFactory,
        address _dac,
        address _child,
        address _mpToken,
        address _lpToken,
        address _votingFactory,
        address _proposer
    ) Deal(
        _id, 
        _dac, 
        _governanceFactory, 
        _mpToken, 
        _lpToken, 
        _votingFactory, 
        _proposer
    ) {
        managedEntity = _child;
    }

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

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == StakedMPManagementType.ChildLPProposalVoting ||
            params.typ == StakedMPManagementType.CreateChildLPProposal ||
            params.typ == StakedMPManagementType.ChildDealVoting
        );
    }

    function _executeStakedMPProposal(StakedMPProposal proposal) internal virtual override {
        StakedMPManagementType typ = proposal.typ();

        if (typ == StakedMPManagementType.CreateChildLPProposal) {
            LPMParams memory childProposal = proposal.getLPMParams();
            uint256 childProposalId = IDACEntity(managedEntity).createLPManagementProposal(childProposal);

            StakedMPParams memory dealProposalParams = StakedMPParams({
                typ: StakedMPManagementType.ChildLPProposalVoting,
                target: address(0),
                id: childProposalId,
                data: abi.encode(true)
            });

            uint256 proposalId = this.createStakedMPProposal(dealProposalParams);

            emit ChildLPVoteCreated(childProposalId, proposalId);
        }
        else if (typ == StakedMPManagementType.ChildLPProposalVoting) {
            uint256 childProposalId = proposal.targetId();
            bool support = proposal.getToggleValue();

            address childVoting = IDACEntity(managedEntity).getProposalVoting(childProposalId);
            IVoting(childVoting).vote(support);

            emit ChildLPVoteCasted(childProposalId, support);
        }
        else if (typ == StakedMPManagementType.ChildDealVoting) {
            uint256 childDealId = proposal.targetId();
            bool support = proposal.getToggleValue();

            address childVoting = IDACEntity(managedEntity).getDealVoting(childDealId);
            IVoting(childVoting).vote(support);

            emit ChildDealVoteCasted(childDealId, support);
        }
        else {
            revert("Unsupported management proposal type for DAC Deal");
        }
    }
}