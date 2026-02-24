// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../interfaces/Structs.sol";

import "../../../kernel/Deal.sol";
import "../../../kernel/governance/DealManagementProposal.sol";
import "../governance/CoreDealManagementProposals.sol";
import "./Permit2Treasury.sol";

contract TreasuryDeal is Deal {
    Permit2Treasury public immutable treasury;

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
        treasury = new Permit2Treasury(address(this), _permit2);
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
            require(this.fundingAmount(trancheId) > 0, "Invalid tranche");
            
            require(
                IERC20(this.fundingToken(trancheId)).transfer(
                    managedEntity, 
                    this.fundingAmount(trancheId)
                ),
                "Transfer failed"
            );
        }
    }

    function _checkStackedMPProposalSupported(ProposalParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == CoreDealManagementType.APPROVE_DIRECT_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_PERMIT2_SPEND ||
            params.typ == CoreDealManagementType.APPROVE_AGENT_SPEND ||
            params.typ == CoreDealManagementType.ASSIGN_CLAIMER ||
            params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC
        );

        if (params.typ == CoreDealManagementType.RETURN_CAPITAL_TO_DAC) {
            require(earlyReturns, "Early returns not allowed");
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
            require(earlyReturns, "Early returns not allowed");

            address token = proposal.target();
            (uint256 amount) = abi.decode(proposal.data(), (uint256));
            
            treasury.returnCapitalToDeal(token, amount);

            IDACEntityAdapter(dacEntity).depositTreasury(token, amount);
            returnedCapital[token] += amount;
            
            emit CapitalReturned(token, amount);
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
            revert("Unsupported management proposal type for Treasury Deal");
        }
    }

    function _beforeReturnCapitalToDAC() internal override {
        // Return full capital for treasury deals is only possible after close
        // even when early returns toggled on. 

        // In case of treasury earlyReturns only makes capital withdraw possible,
        // but pigs need to always use proposals to manage it.

        if (earlyReturns) {
            require(block.timestamp > this.dealDeadline(), "Treasury doesn't support full capital withdraw");
        }

        // Iterate through all funding tokens and return every balance
        address[] memory fundingTokens = this.fundingTokens();
        for (uint256 i = 0; i < fundingTokens.length; i++) {
            address _fundingToken = fundingTokens[i];

            // Claiming the whole balance of any funding token from treasury
            uint256 balance = IERC20(_fundingToken).balanceOf(address(treasury));
            if (balance > 0) {
                treasury.returnCapitalToDeal(_fundingToken, balance);
            }
        }
    }

    function recoverProfits(address token) external onlyStakedMPHolder nonReentrant returns (uint256 amount) {
        require(!(investedCapital[token] > 0), "Invalid token");

        // If token is not a funding token, we allow transfering any balance
        // to treasury (where this balance can be managed by chickens)

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(
            IERC20(token).transfer(managedEntity, balance),
            "Transfer failed"
        );

        return balance;
    }
}