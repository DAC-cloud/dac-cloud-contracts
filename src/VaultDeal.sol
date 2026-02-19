// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Deal.sol";
import "./VaultTreasury.sol";

contract VaultDeal is Deal {
    VaultTreasury public immutable vaultTreasury;

    constructor(
        uint256 _id,
        address _dac,
        address _mpToken,
        address _lpToken,
        address _votingFactory,
        address _proposer,
        bool _isWhitelistOnly,
        address _permit2
    ) Deal(_id, _dac, address(0), _mpToken, _lpToken, _votingFactory, _proposer, _isWhitelistOnly) {
        vaultTreasury = new VaultTreasury(address(this), _permit2);
    }

    function onApproved() public override onlyDACEntity {
        super.onApproved();

        //todo: transfer from DAC approved amount of funds to our treasury
    }

    //todo: proposal management

    // New Permit2 spend approval (called via LPM proposal execution)
    function approvePermit2Spend(bytes32 proposalHash) external onlyDACEntity {
        vaultTreasury.approveSpend(proposalHash);
    }

    // Return capital (only original funding token)
    function returnCapitalToDAC() public override {
        if (msg.sender == dacEntity) {
            require(block.timestamp > dealDeadline, "Deadline not passed");
        }
        else {
            require(stakedMPBalance[msg.sender] != 0, "Not a staked-MP holder");
            if (!earlyReturns) {
                require(block.timestamp > dealDeadline, "Deadline not passed");
            }
        }

        vaultTreasury.returnCapitalToDAC(super.fundingToken());
        super.returnCapitalToDAC(); // update metrics in base
    }
}