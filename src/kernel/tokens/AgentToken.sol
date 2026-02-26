// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IDealCell.sol";

contract AgentToken is ERC20 {
    error NotAuthorized();
    error InvalidDeal();
    error NotTransferable();

    address public immutable dacCell;

    event Staked(address indexed staker, address indexed deal, uint256 amount);
    event StakeRequested(address indexed staker, address indexed deal, uint256 amount);

    constructor(
        address _dacCell, 
        string memory name_, 
        string memory symbol_
    ) ERC20(name_, symbol_) {
        dacCell = _dacCell;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == dacCell, NotAuthorized());
        _mint(to, amount);
    }

    function stakeToDeal(address deal, uint256 amount) external {
        require(IDealCell(deal).isValidDeal(), InvalidDeal());
        require(!IDealCell(deal).isApproved(), InvalidDeal());
        
        _transfer(msg.sender, deal, amount);
        IDealCell(deal).onAgentTokenStaked(msg.sender, amount);
        emit Staked(msg.sender, deal, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == dacCell, NotAuthorized());
        _burn(from, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        require(false, NotTransferable());
        return false;
    }

    function approve(address deal, uint256 amount) public override returns (bool) {
        require(IDealCell(deal).isValidDeal(), InvalidDeal());
        require(IDealCell(deal).isApproved(), InvalidDeal());

        _approve(msg.sender, deal, amount);
        emit StakeRequested(msg.sender, deal, amount);

        return true;
    }
}