// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";
import "./VaultTreasury.sol";

contract VaultDeal is Deal {
    VaultTreasury public immutable vaultTreasury;

    // Events
    event PermitApproved(address indexed treasuryToken, bytes32 permitHash);
    
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
        //todo support tranches
        IERC20(this.fundingToken()).transfer(managedEntity, this.fundingAmount(0));
    }

    function _checkStackedMPProposalSupported(StakedMPParams calldata params) internal virtual override returns (bool supported) {
        supported = (
            params.typ == StakedMPManagementType.ApprovePermit2Spend ||
            params.typ == StakedMPManagementType.ReturnCapitalToDAC
        );
    }

    function _executeStakedMPProposal(StakedMPProposal proposal) internal virtual override {
        StakedMPManagementType typ = proposal.typ();

        if (typ == StakedMPManagementType.ApprovePermit2Spend) {
            bytes32 proposalHash = keccak256(abi.encode(proposal));
            bytes32 permitHash = proposal.getCalldataHash();
            
            vaultTreasury.approveSpend(proposalHash, permitHash);

            emit PermitApproved(proposal.target(), permitHash);
        }
        else if (typ == StakedMPManagementType.ReturnCapitalToDAC) {
            uint256 amount = proposal.getAmount();
            
            vaultTreasury.returnCapitalToDeal(super.fundingToken(), amount);

            IERC20(super.fundingToken()).transfer(dacEntity, amount);
            returnedCapital += amount;
            
            emit CapitalReturned(amount);
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