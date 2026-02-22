// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MPToken.sol";
import "./Interfaces.sol";
import "./LPToken.sol";
import "./IDACEntity.sol";
import "./Deal.sol";

contract DACDeal is Deal {
    uint256 private _childLPAmount;
    uint256 private _capitalCallId;
    
    // Events
    event ChildLPVoteCreated(uint256 indexed childProposalId, uint256 proposalId);
    event ChildLPVoteCasted(uint256 indexed childProposalId, bool support);

    constructor(
        uint256 _id,
        address _governanceFactory,
        address _dac,
        address _child,
        address _mpToken,
        address _lpToken,
        address _proposer
    ) Deal(
        _id, 
        _dac, 
        _governanceFactory, 
        _mpToken, 
        _lpToken, 
        _proposer
    ) {
        managedEntity = _child;
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        _childLPAmount = params.managedEquity;
        _capitalCallId = params.capitalCallId;
    }

    function _afterApprove(uint256 trancheId) internal override {
        // Approving spend towards DAC, so child can fulfill capital call
        // We always approve the last tranche amount, as we immediately sending the funds out
        IERC20(fundingToken()).approve(managedEntity, fundingAmount(trancheId));

        if (trancheId == 0) {
            CapitalCall memory call = CapitalCall({
                treasuryToken: fundingToken(),
                nonce: _capitalCallId,
                lpRecipient: address(this),
                lpAmount: _childLPAmount,
                cashAmount: fundingAmount(trancheId)
            });

            IDACEntity(managedEntity).fulfillCapitalCall(call);
        }

        else {
            address prop = stakedMPProposals[trancheId];
            bytes32 calldataHash = StakedMPProposal(prop).getFundingCalldata();

            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(calldataHash);
            IDACEntity(managedEntity).fulfillCapitalCall(call);

            _childLPAmount += call.lpAmount;
        }
    }

    function _beforeClose() internal override {
        // todo: on close we transfer child equity LP token to our DAC
        //  now this equity is chickens' problem
        //  call depositTreasury on it
        //  they can distribute it as dividends if they want
    }

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == StakedMPManagementType.ChildLPProposalVoting ||
            params.typ == StakedMPManagementType.CreateChildLPProposal
        );
    }

    function _beforeCreateProposal(StakedMPParams calldata params) internal virtual override {
        if (params.typ == StakedMPManagementType.RequestTranche) {
            // Checking that capital call exists
            (uint256 fundingAmount, bytes32 calldataHash) = abi.decode(params.data, (uint256, bytes32));
            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(calldataHash);

            // Verifying capital call parameters
            require(call.treasuryToken == fundingToken());
            require(call.cashAmount == fundingAmount);
            require(call.lpRecipient == address(this));
        }
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
        
        else {
            revert("Unsupported management proposal type for DAC Deal");
        }
    }
}