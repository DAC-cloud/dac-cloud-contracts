// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProposalParams, DealParams, VotingConfig} from "../../../interfaces/Structs.sol";
import {Deal} from "../../../kernel/Deal.sol";
import {IDealCellAdapter} from "../../../kernel/interfaces/IDealCellAdapter.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {DealManagementProposal} from "../../../kernel/governance/DealManagementProposal.sol";
import {CoreDealManagementType} from "../governance/CoreDealManagementProposals.sol";
import {Permit2Treasury, Permit2TreasuryLibrary} from "./Permit2Treasury.sol";

contract TreasuryDeal is Deal {
    Permit2Treasury public immutable treasury;

    error EarlyReturnsNotAllowed();

    error CapitalWithdrawNotSupported();

    error InvalidToken();

    // Events
    event PermitApproved(address indexed treasuryToken, uint160 amount);
    event AgentAssigned(address indexed treasuryToken, address indexed agent, uint160 amount);
    event ProfitsRecovered(address indexed token, uint160 amount);
    
    constructor(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _mpToken,
        address _lpToken,
        address _proposer,
        address _permit2
    ) Deal(
        _id, 
        _dac, 
        _governanceFactory,
        _mpToken, 
        _lpToken, 
        _proposer
    ) {
        treasury = Permit2TreasuryLibrary.deployPermit2Treasury(address(this), _permit2);
        managedEntity = address(treasury);
    }

    function _beforeInitialize(
        DealParams calldata params,
        VotingConfig calldata
    ) internal override pure {
        // Treasury Deal supports opening the wallet without initial funding
    }

    function _afterApprove(uint256 trancheId) internal override {
        if (trancheId > 0) {
            require(IDealCell(dealCell).fundingAmount(trancheId) > 0, InvalidTranche());
            
            require(
                IERC20(IDealCell(dealCell).fundingToken(trancheId)).transfer(
                    managedEntity, 
                    IDealCell(dealCell).fundingAmount(trancheId)
                ),
                TransferFailed()
            );
        }
    }

    function _checkStackedAgentProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND ||
            params.typ == CoreDealManagementType.ASSIGN_CLAIMER ||
            params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC
        );

        if (params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC) {
            require(IDealCell(dealCell).allowEarlyReturns(), EarlyReturnsNotAllowed());
        }
    }

    function _executeModuleManagementProposal(DealManagementProposal proposal) internal virtual override {
        bytes4 typ = proposal.typ();

        if (typ == CoreDealManagementType.APPROVE_DIRECT_SPEND) {
            // TODO: Send transfer from treasury
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
            require(IDealCell(dealCell).allowEarlyReturns(), EarlyReturnsNotAllowed());

            address token = proposal.target();
            (uint256 amount) = abi.decode(proposal.data(), (uint256));
            
            treasury.returnCapitalToDeal(token, amount);

            require(IERC20(token).approve(dealCell, amount), TransferFailed());
            
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
            // TODO: Approve agents to spend from treasury
        }

        else {
            require(false, CapitalWithdrawNotSupported());
        }
    }

    function _beforeWithdrawCapital() internal override {
        // Return full capital for treasury deals is only possible after close
        // even when early returns toggled on. 

        // In case of treasury earlyReturns only makes capital withdraw possible,
        // but pigs need to always use proposals to manage it.

        if (IDealCell(dealCell).allowEarlyReturns()) {
            require(block.timestamp > IDealCell(dealCell).dealDeadline(), CapitalWithdrawNotSupported());
        }

        // Iterate through all funding tokens and return every balance
        address[] memory fundingTokens = IDealCell(dealCell).fundingTokens();
        for (uint256 i = 0; i < fundingTokens.length; i++) {
            address _fundingToken = fundingTokens[i];

            // Claiming the whole balance of any funding token from treasury
            uint256 balance = IERC20(_fundingToken).balanceOf(address(treasury));
            if (balance > 0) {
                treasury.returnCapitalToDeal(_fundingToken, balance);

                require(IERC20(_fundingToken).approve(dealCell, balance), TransferFailed());

                IDealCellAdapter(dealCell).transferCapital(_fundingToken, balance);
            }
        }
    }

    function recoverProfits(address token) external onlyStakedAgent nonReentrant returns (uint256 amount) {
        require(!(IDealCell(dealCell).getInvestedCapital(token) > 0), InvalidToken());

        // If token is not a funding token, we allow transfering any balance
        // to treasury (where this balance can be managed by chickens)

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(
            IERC20(token).transfer(managedEntity, balance),
            TransferFailed()
        );

        return balance;
    }
}