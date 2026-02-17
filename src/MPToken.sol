// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./IDeal.sol";

contract MPToken is ERC20 {
    uint256 public immutable maxSupply;
    address public immutable dacEntity;

    constructor(uint256 _maxSupply, address _dacEntity, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        maxSupply = _maxSupply;
        dacEntity = _dacEntity;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(totalSupply() + amount <= maxSupply, "Exceeds max");
        _mint(to, amount);
    }

    function stakeToDeal(address deal, uint256 amount) external {
        require(IDeal(deal).isValidDeal(), "Invalid Deal");
        _transfer(msg.sender, deal, amount);
        IDeal(deal).onMPStaked(msg.sender, amount);
        emit Staked(msg.sender, deal, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == dacEntity, "Only DAC");
        _burn(from, amount);
    }

    event Staked(address indexed staker, address indexed deal, uint256 amount);
}