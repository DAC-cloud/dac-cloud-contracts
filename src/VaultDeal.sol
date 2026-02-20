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

    function onApproved() public override onlyDACEntity {
        super.onApproved();

        IERC20(this.fundingToken()).transfer(managedEntity, this.fundingAmount());
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
            uint256 amount = proposal.getAmountReturned();
            
            vaultTreasury.returnCapitalToDeal(super.fundingToken(), amount);

            IERC20(super.fundingToken()).transfer(dacEntity, amount);
            returnedCapital += amount;
            
            emit CapitalReturned(amount);
        }
        else {
            revert("Unsupported management proposal type for Vault Deal");
        }
    }

    // Force return capital
    function returnCapitalToDAC() public override {
        // Claiming the whole balance of fundingToken from treasury
        uint256 balance = IERC20(super.fundingToken()).balanceOf(address(vaultTreasury));
        vaultTreasury.returnCapitalToDeal(super.fundingToken(), balance);

        // Transfer all capital accumulated in the Deal to DAC
        super.returnCapitalToDAC();
    }
}