// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProposalParams, DealParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {Deal} from "../../../kernel/Deal.sol";
import {IDealCellAdapter} from "../../../kernel/interfaces/IDealCellAdapter.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {DealManagementProposal} from "../../../kernel/governance/DealManagementProposal.sol";
import {CoreDealManagementType} from "../governance/CoreDealManagementProposals.sol";
import {Permit2Treasury, Permit2TreasuryFactory} from "./Permit2Treasury.sol";
import {TreasurySpendAllowance} from "../interfaces/Structs.sol";
import {DACErrorsLib} from "../../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../../interfaces/DACEventsLib.sol";

contract TreasuryDeal is Deal {
    using SafeERC20 for IERC20;

    Permit2Treasury public treasury;

    // Events
    event PermitApproved(address indexed treasuryToken, uint160 amount);
    event AgentAssigned(address indexed treasuryToken, address indexed agent, uint160 amount);
    event AgentAllowed(address indexed treasuryToken, address indexed agent, uint160 amount, uint160 dealSize);
    event ProfitsRecovered(address indexed token, uint160 amount);
    
    function initialize(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _agentToken,
        address _mainToken,
        address _proposer,
        address _permit2TreasuryFactory,
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

        treasury = Permit2TreasuryFactory(_permit2TreasuryFactory).deployPermit2Treasury(address(this));
        managedEntity = address(treasury);
    }

    function _afterInitialize(
        DealParams calldata,
        VotingConfig calldata
    ) internal override {
        // Treasury Deal supports opening the wallet without initial funding

        IDealCellAdapter(dealCell).registerControlledAddress(address(treasury));
    }

    function _afterApprove(uint256 trancheId) internal override {
        if (trancheId > 0) {
            require(IDealCell(dealCell).fundingTranche(trancheId).amount > 0, DACErrorsLib.InvalidTranche());
        }

        if (IDealCell(dealCell).fundingTranche(trancheId).amount > 0) {
            require(
                IERC20(
                    IDealCell(dealCell).fundingTranche(trancheId).token
                ).transfer(
                    managedEntity, 
                    IDealCell(dealCell).fundingTranche(trancheId).amount
                ),
                DACErrorsLib.TransferFailed()
            );
        }
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND ||
            params.typ == CoreDealManagementType.ASSIGN_CLAIMER ||
            params.typ == CoreDealManagementType.REVOKE_AGENT ||
            params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC ||
            params.typ == CoreDealManagementType.DELEGATE_VOTE_RIGHTS
        );

        if (params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC) {
            require(IDealCell(dealCell).allowEarlyReturns(), DACErrorsLib.EarlyReturnsNotAllowed());
        }
    }

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.APPROVE_DIRECT_SPEND) {
            address token = proposal.target();
            (address spender, uint160 amount) = abi.decode(
                proposal.data(),
                (address, uint160)
            );
            
            treasury.directSpend(token, spender, amount);
        }

        else if (typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND) {
            address token = proposal.target();
            (address spender, uint160 amount, uint48 expiration) = abi.decode(
                proposal.data(),
                (address, uint160, uint48)
            );
            
            treasury.approveSpend(token, spender, amount, expiration);

            emit PermitApproved(proposal.target(), amount);
        }

        else if (typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC) {
            require(IDealCell(dealCell).allowEarlyReturns(), DACErrorsLib.EarlyReturnsNotAllowed());

            address token = proposal.target();
            (uint256 amount) = abi.decode(proposal.data(), (uint256));
            
            treasury.returnCapitalToDeal(token, amount);

            IERC20(token).forceApprove(dealCell, amount);
            
            IDealCellAdapter(dealCell).transferCapital(token, amount);
        }

        else if (typ == CoreDealManagementType.ASSIGN_CLAIMER) {
            address agent = proposal.target();
            (address token, address counterparty, uint160 amount) = abi.decode(
                proposal.data(), 
                (address, address, uint160)
            );
            
            treasury.approveReceive(agent, counterparty, token, amount);

            emit AgentAssigned(token, agent, amount);
        }

        else if (typ == CoreDealManagementType.APPROVE_AGENT_SPEND) {
            address token = proposal.target();
            (address agent, address destination, TreasurySpendAllowance memory allowance) = abi.decode(
                proposal.data(),
                (address, address, TreasurySpendAllowance)
            );


            treasury.approveSpendAllowance(agent, token, destination, allowance);

            emit AgentAllowed(token, agent, allowance.totalAmount, allowance.singleTxAmount);
        }

        else if (typ == CoreDealManagementType.REVOKE_AGENT) {
            address token = proposal.target();
            (address agent, address counterparty) = abi.decode(
                proposal.data(),
                (address, address)
            );

            treasury.rewokeAgent(agent, token, counterparty);
        }

        else if (typ == CoreDealManagementType.DELEGATE_VOTE_RIGHTS) {
            (address token, address delegatee) = abi.decode(
                proposal.data(),
                (address, address)
            );

            treasury.delegateVotes(token, delegatee);

            emit DACEventsLib.VotesDelegated(token, delegatee);
        }

        else {
            revert DACErrorsLib.CapitalWithdrawNotSupported();
        }
    }

    function _beforeWithdrawCapital() internal override {
        // Return full capital for treasury deals is only possible after close
        // even when early returns toggled on. 

        // In case of treasury earlyReturns only makes capital withdraw possible,
        // but pigs need to always use proposals to manage it.

        if (IDealCell(dealCell).allowEarlyReturns()) {
            require(
                block.timestamp > IDealCell(dealCell).dealDeadline(), 
                DACErrorsLib.CapitalWithdrawNotSupported()
            );
        }

        // Iterate through all funding tokens and return every balance
        address[] memory fundingTokens = IDealCell(dealCell).fundingTokens();
        for (uint256 i = 0; i < fundingTokens.length; i++) {
            address _fundingToken = fundingTokens[i];

            // Claiming the whole balance of any funding token from treasury
            uint256 balance = IERC20(_fundingToken).balanceOf(address(treasury));
            if (balance > 0) {
                treasury.returnCapitalToDeal(_fundingToken, balance);

                IERC20(_fundingToken).forceApprove(dealCell, balance);

                IDealCellAdapter(dealCell).transferCapital(_fundingToken, balance);
            }
        }
    }

    function recoverProfits(address token) external onlyStakedAgent nonReentrant returns (uint256 amount) {
        require(!(IDealCell(dealCell).getInvestedCapital(token) > 0), DACErrorsLib.InvalidToken());

        // If token is not a funding token, we allow transfering any balance
        // to treasury (where this balance can be managed by chickens)

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(
            IERC20(token).transfer(managedEntity, balance),
            DACErrorsLib.TransferFailed()
        );

        return balance;
    }
}
