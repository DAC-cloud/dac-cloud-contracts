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
    ) {}

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        managedEntity = params.dealTarget;

        _childLPAmount = params.managedEquity;
        _capitalCallId = params.capitalCallId;
    }

    function _afterApprove(uint256 trancheId) internal override {
        // Approving spend towards DAC, so child can fulfill capital call
        // We always approve the last tranche amount, as we immediately sending the funds out
        IERC20(fundingToken(trancheId)).approve(managedEntity, fundingAmount(trancheId));

        if (trancheId == 0) {
            CapitalCall memory call = CapitalCall({
                treasuryToken: fundingToken(trancheId),
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
        // On close we transfer child equity LP token to our DAC
        // Now this equity is chickens' problem, they can distribute 
        // these LP tokens as dividends, or establish a new Deal
        // with new management

        //todo:
        //  call depositTreasury on it  
    }

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == StakedMPManagementType.ChildLPProposalVoting ||
            params.typ == StakedMPManagementType.CreateChildLPProposal ||
            params.typ == StakedMPManagementType.ReinvestProfits
        );
    }

    //todo: in DAC deal, need to support tranches in other tokens

    function _beforeCreateProposal(StakedMPParams calldata params) internal virtual override {
        if (params.typ == StakedMPManagementType.RequestTranche) {
            // Checking that capital call exists
            (uint256 fundingAmount, bytes32 calldataHash) = abi.decode(params.data, (uint256, bytes32));
            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(calldataHash);

            // Verifying capital call parameters
            require(call.treasuryToken == params.target);
            require(call.cashAmount == fundingAmount);
            require(call.lpRecipient == address(this));
        }

        else if (params.typ == StakedMPManagementType.ReinvestProfits) {
            // Checking a reinvest profit proposal
            address token = params.target;
            (uint256 fundingAmount, bytes32 capitalCallHash) = abi.decode(params.data, (uint256, bytes32));

            // If token is our funding token
            if (investedCapital[token] > 0) {
                // With early returns, all capital in any of funding tokens is siphoned back
                // to chickens by any manager will, and automatically counts into returns
                // so we make reinvest not possible
                if (params.typ == StakedMPManagementType.ReinvestProfits) {
                    require(!earlyReturns, "Early returns are toggled on");
                }
            }
            else {
                address lpTokenAddress = IDACEntityAdapter(managedEntity).getLPToken();
                require(token != lpTokenAddress);
            }
            
            require(
                IERC20(token).balanceOf(address(this)) >= fundingAmount,
                "Balance of the token is not enough"
            );

            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(capitalCallHash);

            require(call.treasuryToken == token);
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
        
        else if (typ == StakedMPManagementType.ReinvestProfits) {
            address token = proposal.target();
            uint256 amount = proposal.getFundingAmount();
            bytes32 callHash = proposal.getFundingCalldata();

            IERC20(token).approve(managedEntity, amount);

            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(callHash);
            IDACEntity(managedEntity).fulfillCapitalCall(call);

            _childLPAmount += call.lpAmount;
        }

        else {
            revert("Unsupported management proposal type for DAC Deal");
        }
    }

    function _beforeReturnCapitalToDAC() internal override {
        // DAC deal always transfer capital in all funding tokens back to parent DAC
        // following the core return logic and `earlyReturns` configuration

        // If early returns logic is not turned-on, DAC deal can reinvest
        // profits in the funding token into a child DAC
    }
}