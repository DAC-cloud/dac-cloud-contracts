// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../interfaces/Structs.sol";
import "../../../interfaces/IDACEntity.sol";
import "../../../kernel/governance/DealManagementProposal.sol";
import "../../../kernel/governance/AbstractDealManagementProposals.sol";
import "../../../kernel/tokens/MPToken.sol";
import "../../../kernel/tokens/LPToken.sol";
import "../../../kernel/Deal.sol";
import "../governance/CoreDealManagementProposals.sol";

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

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override pure {
        require(params.fundingAmount > 0, "DAC deal should include funding");
    }

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
            address prop = getProposal(trancheId);

            (, bytes32 calldataHash) = abi.decode(
                DealManagementProposal(prop).data(), 
                (uint256, bytes32)
            );

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

        address token = IDACEntityAdapter(managedEntity).getLPToken();

        IERC20(token).approve(dacEntity, _childLPAmount);

        IDACEntityAdapter(dacEntity).depositTreasury(token, _childLPAmount);
        returnedCapital[token] += _childLPAmount;
    }

    function _checkStackedMPProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.CREATE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.REINVEST_PROFITS
        );
    }

    function _beforeCreateProposal(ProposalParams calldata params) internal virtual override {
        if (params.typ == AbstractDealManagementType.REQUEST_TRANCHE) {
            // Checking that capital call exists
            (uint256 fundingAmount, bytes32 calldataHash) = abi.decode(params.data, (uint256, bytes32));
            CapitalCall memory call = IDACEntity(managedEntity).getCapitalCall(calldataHash);

            // Verifying capital call parameters
            require(call.treasuryToken == params.target);
            require(call.cashAmount == fundingAmount);
            require(call.lpRecipient == address(this));
        }

        else if (params.typ == CoreDealManagementType.REINVEST_PROFITS) {
            // Checking a reinvest profit proposal
            address token = params.target;
            (uint256 fundingAmount, bytes32 capitalCallHash) = abi.decode(params.data, (uint256, bytes32));

            // If token is our funding token
            if (investedCapital[token] > 0) {
                // With early returns, all capital in any of funding tokens is siphoned back
                // to chickens by any manager will, and automatically counts into returns
                // so we make reinvest not possible
                require(!earlyReturns, "Early returns are toggled on");
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

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.CREATE_DAC_PROPOSAL) {
            (ProposalParams memory childProposal) = abi.decode(
                proposal.data(), 
                (ProposalParams)
            );

            uint256 childProposalId = IDACEntity(managedEntity).createLPManagementProposal(childProposal);

            ProposalParams memory dealProposalParams = ProposalParams({
                typ: CoreDealManagementType.VOTE_DAC_PROPOSAL,
                target: address(0),
                i: bytes32(childProposalId),
                data: abi.encode(true)
            });

            uint256 proposalId = this.createStakedMPProposal(dealProposalParams);

            emit ChildLPVoteCreated(childProposalId, proposalId);
        }

        else if (typ == CoreDealManagementType.VOTE_DAC_PROPOSAL) {
            uint256 childProposalId = uint256(proposal.i());
            (bool support) = abi.decode(
                proposal.data(), 
                (bool)
            );

            address childVoting = IDACEntity(managedEntity).getProposalVoting(childProposalId);
            IVoting(childVoting).vote(support);

            emit ChildLPVoteCasted(childProposalId, support);
        }
        
        else if (typ == CoreDealManagementType.REINVEST_PROFITS) {
            address token = proposal.target();
            (uint256 amount, bytes32 callHash) = abi.decode(proposal.data(), (uint256, bytes32));

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