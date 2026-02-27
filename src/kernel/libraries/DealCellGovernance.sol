// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/Structs.sol";
import "../../interfaces/IDeal.sol";
import "../../interfaces/IDealCell.sol";
import "../interfaces/Structs.sol";
import "../tokens/StakedAgent.sol";

interface IDealGovernanceAdapter {
    function closeDeal()
        external;
}

library DealCellGovernance {

    error DeadlineNotPassed();
    error NotStakedAgent();

    error InsufficientRewards();

    error TransferFailed();

    event CapitalReturned(address indexed dac, uint256 indexed id, address token, uint256 amount);

    event RewardsAllocated(address indexed dac, uint256 indexed id, uint256 reward);
    event StakesSlashed(address indexed dac, uint256 indexed id, uint256 slashAmount);
    
    function prepareWithdrawal(
        address dealCell
    ) public {
        address[] memory _fundingTokens = IDealCell(dealCell).fundingTokens();

        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(_fundingToken).approve(dealCell, balance);
        }
    }

    function withdrawCapital(
        uint256 id,
        bool earlyReturns,
        address dacCell,
        uint256 _dealDeadline,
        StakedAgent token,
        IDeal deal,
        address[] storage _fundingTokens,
        mapping(address => uint256) storage returnedCapital
    ) public {
        if (msg.sender == dacCell) {
            require(block.timestamp > _dealDeadline, DeadlineNotPassed());
        }
        else {
            require(token.balanceOf(msg.sender) != 0, NotStakedAgent());
            if (!earlyReturns) {
                require(block.timestamp > _dealDeadline, DeadlineNotPassed());
            }
        }
        
        deal.beforeWithdrawCapital();

        // Iterate through all funding tokens and return every balance
        for (uint256 i = 0; i < _fundingTokens.length; i++) {
            address _fundingToken = _fundingTokens[i];

            uint256 dealAllowance = IERC20(_fundingToken).allowance(address(deal), address(this));
            if (dealAllowance > 0) {
                require(
                    IERC20(_fundingToken).transferFrom(address(deal), address(this), dealAllowance),
                    TransferFailed()
                );
            }

            //todo: transfer from deal

            uint256 balance = IERC20(_fundingToken).balanceOf(address(this));
            if (balance == 0) continue;

            IERC20(_fundingToken).approve(dacCell, balance);

            IDACCellAdapter(dacCell).depositTreasury(_fundingToken, balance);
            returnedCapital[_fundingToken] += balance;
            
            emit CapitalReturned(dacCell, id, _fundingToken, balance);
        }

        deal.afterWithdrawCapital();
    }

    function markAsSuccess(
        uint256 rewardPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        uint256 rewardsConverted,
        uint256 _tokenRewardsLimit,
        address[] storage holders,
        mapping(address => uint256) storage claimableRewards,
        address self
    ) public {
        require(rewardsConverted + rewardPercent <= 100, InsufficientRewards());

        deal.onMarkAsSuccess(rewardPercent);

        uint256 reward = (_tokenRewardsLimit * rewardPercent) / 100;

        uint256 transformAmount = reward; // for event

        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderShare = (token.balanceOf(h) * reward) / token.totalSupply();  // pro-rata on original stake
            claimableRewards[h] = holderShare;
        }

        rewardsConverted += rewardPercent;

        // if all rewards were paid out, marking the deal as closed so MP tokens can withdraw stakes
        if (rewardsConverted == 100) {
            IDealGovernanceAdapter(self).closeDeal();
        }

        emit RewardsAllocated(dacCell, id, transformAmount);
    }

    function markAsFailed(
        uint256 slashPercent,
        uint256 id,
        address dacCell,
        StakedAgent token,
        IDeal deal,
        address[] storage holders
    ) public {
        uint256 slashAmount = (token.totalSupply() * slashPercent) / 100;
        for (uint256 i = 0; i < holders.length; i++) {
            address h = holders[i];
            uint256 holderSlash = (token.balanceOf(h) * slashPercent) / 100;
            token.burn(h, holderSlash);
        }
        
        emit StakesSlashed(dacCell, id, slashAmount);

        deal.onMarkAsFailed(slashPercent);
    }
}