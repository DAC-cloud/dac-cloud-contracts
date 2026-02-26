// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../interfaces/Structs.sol";
import "../../../interfaces/IDACCell.sol";
import "../../../interfaces/IDACFactory.sol";
import "../../../kernel/governance/DealManagementProposal.sol";
import "../../../kernel/governance/AbstractDealManagementProposals.sol";
import "../../../kernel/tokens/AgentToken.sol";
import "../../../kernel/tokens/MainToken.sol";
import "../../../kernel/Deal.sol";
import "../interfaces/Structs.sol";
import "../governance/CoreDealManagementProposals.sol";

contract DACDeal is Deal {

    error NoFunding();
    error ConfigMismatchParams();
    error NotAllowed();
    error UnsupportedProposal();

    uint256 private _allocation;
    uint256 private _rootCapitalCallId;
    
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
    ) internal override {
        require(params.fundingAmount > 0, NoFunding());

        if (params.dealTarget == address(0)) {
            (DACDealConfig memory dacDeal) = abi.decode(params.dealConfig, (DACDealConfig));
            (address dacFactory, bytes32 salt, DACConfig memory config) = abi.decode(dacDeal.config, (address, bytes32, DACConfig));

            require(config.founderAllocation == dacDeal.managedEquity, ConfigMismatchParams());
            require(config.treasuryToken == params.fundingToken, ConfigMismatchParams());
            require(config.founderCommitment == params.fundingAmount, ConfigMismatchParams());

            config.founder = address(this);

            (address dacAddr,,) = IDACFactory(dacFactory).deployDAC(config, salt);

            managedEntity = dacAddr;
            _allocation = config.founderAllocation;
        }
    }

    function _afterInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        (DACDealConfig memory dacDeal) = abi.decode(params.dealConfig, (DACDealConfig));

        if (params.dealTarget != address(0)) {
            managedEntity = params.dealTarget;

            _rootCapitalCallId = dacDeal.capitalCallId;
            _allocation = dacDeal.managedEquity;
        }
    }

    function _afterApprove(uint256 trancheId) internal override {
        // Approving spend towards DAC, so child can fulfill capital call
        // We always approve the last tranche amount, as we immediately sending the funds out
        IERC20(IDealCell(dealCell).fundingToken(trancheId)).approve(managedEntity, IDealCell(dealCell).fundingAmount(trancheId));

        if (trancheId == 0) {
            CapitalCall memory call = CapitalCall({
                treasuryToken: IDealCell(dealCell).fundingToken(trancheId),
                nonce: _rootCapitalCallId,
                tokenRecipient: address(this),
                tokenAmount: _allocation,
                cashAmount: IDealCell(dealCell).fundingAmount(trancheId)
            });

            IDACCell(managedEntity).fulfillCapitalCall(call);
        }

        else {
            address prop = getProposal(trancheId);

            (, bytes32 calldataHash) = abi.decode(
                DealManagementProposal(prop).data(), 
                (uint256, bytes32)
            );

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(calldataHash);
            IDACCell(managedEntity).fulfillCapitalCall(call);

            _allocation += call.tokenAmount;
        }
    }

    function _beforeClose() internal override {
        // On close we transfer child equity LP token to our DAC
        // Now this equity is chickens' problem, they can distribute 
        // these LP tokens as dividends, or establish a new Deal
        // with new management

        address token = IDACCellAdapter(managedEntity).getMainToken();

        IERC20(token).approve(dacCell, _allocation);

        //todo: move capital through dealCell

        IDACCellAdapter(dacCell).depositTreasury(token, _allocation);
        //returnedCapital[token] += _allocation;
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
            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(calldataHash);

            // Verifying capital call parameters
            require(call.treasuryToken == params.target);
            require(call.cashAmount == fundingAmount);
            require(call.tokenRecipient == address(this));
        }

        else if (params.typ == CoreDealManagementType.REINVEST_PROFITS) {
            // Checking a reinvest profit proposal
            address token = params.target;
            (uint256 fundingAmount, bytes32 capitalCallHash) = abi.decode(params.data, (uint256, bytes32));

            // If token is our funding token
            if (IDealCell(dealCell).getInvestedCapital(token) > 0) {
                // With early returns, all capital in any of funding tokens is siphoned back
                // to chickens by any manager will, and automatically counts into returns
                // so we make reinvest not possible
                require(!earlyReturns, NotAllowed());
            }
            else {
                address lpTokenAddress = IDACCellAdapter(managedEntity).getMainToken();
                require(token != lpTokenAddress);
            }
            
            require(
                IERC20(token).balanceOf(address(this)) >= fundingAmount,
                NotEnoughBalance()
            );

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(capitalCallHash);

            require(call.treasuryToken == token);
            require(call.cashAmount == fundingAmount);
            require(call.tokenRecipient == address(this));
        }
    }

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.CREATE_DAC_PROPOSAL) {
            (ProposalParams memory childProposal) = abi.decode(
                proposal.data(), 
                (ProposalParams)
            );

            uint256 childProposalId = IDACCell(managedEntity).createManagementProposal(childProposal);

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

            address childVoting = IDACCell(managedEntity).getProposalVoting(childProposalId);
            IVoting(childVoting).vote(support);

            emit ChildLPVoteCasted(childProposalId, support);
        }
        
        else if (typ == CoreDealManagementType.REINVEST_PROFITS) {
            address token = proposal.target();
            (uint256 amount, bytes32 callHash) = abi.decode(proposal.data(), (uint256, bytes32));

            IERC20(token).approve(managedEntity, amount);

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(callHash);
            IDACCell(managedEntity).fulfillCapitalCall(call);

            _allocation += call.tokenAmount;
        }

        else {
            require(false, UnsupportedProposal());
        }
    }

    function _beforeWithdrawCapital() internal override {
        // DAC deal always transfer capital in all funding tokens back to parent DAC
        // following the core return logic and `earlyReturns` configuration

        // If early returns logic is not turned-on, DAC deal can reinvest
        // profits in the funding token into a child DAC
    }
}