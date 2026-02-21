// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";
import "./VaultTreasury.sol";

contract VaultDeal is Deal {
    VaultTreasury public immutable vaultTreasury;

    // Events
    event PermitApproved(address indexed treasuryToken, uint160 amount);
    event AgentAssigned(address indexed treasuryToken, address indexed agent, uint160 amount);
    
    constructor(
        uint256 _id,
        address _dac,
        address _governanceFactory,
        address _mpToken,
        address _lpToken,
        address _votingFactory,
        address _proposer,
        address _permit2
    ) Deal(
        _id, 
        _dac, 
        _governanceFactory,
        _mpToken, 
        _lpToken, 
        _votingFactory, 
        _proposer
    ) {
        vaultTreasury = new VaultTreasury(address(this), _permit2);
        managedEntity = address(vaultTreasury);
    }

    function _afterApprove(uint256 trancheId) internal override {
        require(
            IERC20(this.fundingToken()).transfer(
                managedEntity, 
                this.fundingAmount(trancheId)
            ),
            "Transfer failed"
        );
    }

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == StakedMPManagementType.ApprovePermit2Spend ||
            params.typ == StakedMPManagementType.ReturnCapitalToDAC ||
            params.typ == StakedMPManagementType.AssignClaimer
        );
    }

    function _executeStakedMPProposal(StakedMPProposal proposal) internal virtual override {
        StakedMPManagementType typ = proposal.typ();

        if (typ == StakedMPManagementType.ApprovePermit2Spend) {
            address token = proposal.target();
            (address spender, uint160 amount, uint48 expiration) = proposal.getApproveCallData();
            
            vaultTreasury.approveSpend(token, spender, amount, expiration);

            emit PermitApproved(proposal.target(), amount);
        }

        else if (typ == StakedMPManagementType.ReturnCapitalToDAC) {
            uint256 amount = proposal.getAmount();
            
            vaultTreasury.returnCapitalToDeal(super.fundingToken(), amount);

            require(IERC20(super.fundingToken()).transfer(dacEntity, amount), "Transfer failed");
            returnedCapital += amount;
            
            emit CapitalReturned(amount);
        }

        else if (typ == StakedMPManagementType.AssignClaimer) {
            address agent = proposal.target();
            (address token, address counterparty, uint160 amount) = proposal.getApproveAgentCallData();
            
            vaultTreasury.approveReceive(agent, counterparty, token, amount);

            emit AgentAssigned(token, agent, amount);
        }

        else if (typ == StakedMPManagementType.ApproveAgentSpend) {
            // TODO: Approve agents to spend from treasury
        }

        else {
            revert("Unsupported management proposal type for Vault Deal");
        }
    }

    function _beforeReturnCapitalToDAC() internal override {
        // Claiming the whole balance of fundingToken from treasury
        uint256 balance = IERC20(super.fundingToken()).balanceOf(address(vaultTreasury));
        vaultTreasury.returnCapitalToDeal(super.fundingToken(), balance);
    }
}