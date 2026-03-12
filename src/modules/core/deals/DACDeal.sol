// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProposalParams, DealParams, VotingConfig, DACConfig, CapitalCall} from "../../../interfaces/Structs.sol";
import {IVotes} from "../../../lib/IVotes.sol";
import {IVoting} from "../../../interfaces/IVoting.sol";
import {IDACCell} from "../../../interfaces/IDACCell.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {IDACFactory} from "../../../interfaces/IDACFactory.sol";
import {DealManagementProposal} from "../../../kernel/governance/DealManagementProposal.sol";
import {IDACCell} from "../../../interfaces/IDACCell.sol";
import {IDealCellAdapter} from "../../../kernel/interfaces/IDealCellAdapter.sol";
import {AbstractDealManagementType} from "../../../kernel/governance/AbstractDealManagementProposals.sol";
import {Deal} from "../../../kernel/Deal.sol";
import {DACDealConfig} from "../interfaces/Structs.sol";
import {CoreDealManagementType} from "../governance/CoreDealManagementProposals.sol";
import {DACErrorsLib} from "../../../interfaces/DACErrorsLib.sol";

contract DACDeal is Deal {
    using SafeERC20 for IERC20;

    struct DACCellDNA {
        address dacMainToken;
        address dacAgentToken;
    }

    uint256 private _allocation;
    uint256 private _rootCapitalCallId;
    
    DACCellDNA public dacCellDNA;
    
    // Events
    event ChildVoteCreated(uint256 indexed childProposalId, uint256 proposalId);
    event ChildVoteCasted(uint256 indexed childProposalId, bool support);

    function initialize(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer,
        address _factory
    ) external initializer {
        __Deal_init(
            _id,
            _dac,
            _governanceFactory,
            _agentToken,
            _mainToken,
            _proposer,
            _factory
        );
    }

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override {
        require(params.fundingAmount > 0, DACErrorsLib.NoFunding());

        if (params.dealTarget == address(0)) {
            (DACDealConfig memory dacDeal) = abi.decode(params.dealConfig, (DACDealConfig));
            (address dacFactory, address deployer, bytes32 salt, DACConfig memory config) = abi.decode(dacDeal.config, (address, address, bytes32, DACConfig));

            require(config.founderAllocation == dacDeal.managedEquity, DACErrorsLib.ConfigMismatchParams());
            require(config.treasuryToken == params.fundingToken, DACErrorsLib.ConfigMismatchParams());
            require(config.founderCommitment == params.fundingAmount, DACErrorsLib.ConfigMismatchParams());

            config.founder = address(this);

            (address dacAddr, address mainTokenAddr, address agentTokenAddr) = IDACFactory(dacFactory).deployDAC(config, salt, deployer);

            managedEntity = dacAddr;
            dacCellDNA = DACCellDNA({
                dacMainToken: mainTokenAddr,
                dacAgentToken: agentTokenAddr
            });
            
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

            dacCellDNA = DACCellDNA({
                dacMainToken: IDACCell(params.dealTarget).getMainToken(),
                dacAgentToken: IDACCell(params.dealTarget).getAgentToken()
            });

            _rootCapitalCallId = dacDeal.capitalCallId;
            _allocation = dacDeal.managedEquity;
        }
    }

    function _afterApprove(uint256 trancheId) internal override {
        // Approving spend towards DAC, so child can fulfill capital call
        // We always approve the last tranche amount, as we immediately sending the funds out

        address token = IDealCell(dealCell).fundingTranche(trancheId).token;
        uint256 amount = IDealCell(dealCell).fundingTranche(trancheId).amount;

        IERC20(token).forceApprove(managedEntity, amount);

        if (trancheId == 0) {
            CapitalCall memory call = CapitalCall({
                treasuryToken: token,
                nonce: _rootCapitalCallId,
                tokenRecipient: address(this),
                tokenAmount: _allocation,
                cashAmount: amount
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

        IVotes(IDACCell(managedEntity).getMainToken()).delegate(address(this));
    }

    function _beforeClose() internal override {
        // On close we transfer child Main token to our DAC
        // Now this equity is chickens' problem, they can distribute 
        // these equity tokens as dividends, or establish a new Deal
        // with new management

        address token = IDACCell(managedEntity).getMainToken();

        IERC20(token).forceApprove(dealCell, _allocation);

        IDealCellAdapter(dealCell).transferCapital(token, _allocation);
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.REINVEST_PROFITS ||
            params.typ == CoreDealManagementType.CREATE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.VOTE_DAC_PROPOSAL ||
            params.typ == CoreDealManagementType.RETURN_PROFITS
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
                require(!IDealCell(dealCell).allowEarlyReturns(), DACErrorsLib.NotAllowed());
            }
            else {
                address mainTokenAddress = IDACCell(managedEntity).getMainToken();
                require(token != mainTokenAddress);
            }
            
            require(
                IERC20(token).balanceOf(address(this)) >= fundingAmount,
                DACErrorsLib.NotEnoughBalance()
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

            uint256 proposalId = this.createStakedAgentProposal(dealProposalParams);

            emit ChildVoteCreated(childProposalId, proposalId);
        }

        else if (typ == CoreDealManagementType.VOTE_DAC_PROPOSAL) {
            uint256 childProposalId = uint256(proposal.i());
            (bool support) = abi.decode(
                proposal.data(), 
                (bool)
            );

            address childVoting = IDACCell(managedEntity).getProposalVoting(childProposalId);
            IVoting(childVoting).vote(support);

            emit ChildVoteCasted(childProposalId, support);
        }
        
        else if (typ == CoreDealManagementType.REINVEST_PROFITS) {
            address token = proposal.target();
            (uint256 amount, bytes32 callHash) = abi.decode(proposal.data(), (uint256, bytes32));

            IERC20(token).forceApprove(managedEntity, amount);

            CapitalCall memory call = IDACCell(managedEntity).getCapitalCall(callHash);
            IDACCell(managedEntity).fulfillCapitalCall(call);

            _allocation += call.tokenAmount;
        }

        else if (typ == CoreDealManagementType.RETURN_PROFITS) {
            address token = proposal.target();
            (uint256 amount) = abi.decode(proposal.data(), (uint256));
            
            require(token != IDACCell(managedEntity).getMainToken(), DACErrorsLib.NotAllowed());

            IERC20(token).forceApprove(dealCell, amount);
            IDealCellAdapter(dealCell).transferCapital(token, amount);
        }

        else {
            revert DACErrorsLib.UnsupportedProposal();
        }
    }

    function _beforeWithdrawCapital() internal override {
        // DAC deal always transfer capital in all funding tokens back to parent DAC
        // following the core return logic and `earlyReturns` configuration

        // If early returns logic is not turned-on, DAC deal can reinvest
        // profits in the funding token into a child DAC
    }
}
