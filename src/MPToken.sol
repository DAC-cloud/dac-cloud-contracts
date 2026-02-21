// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./IDealCore.sol";

contract MPToken is ERC20 {
    address public immutable dacEntity;

    event Staked(address indexed staker, address indexed deal, uint256 amount);
    event StakeRequested(address indexed staker, address indexed deal, uint256 amount);

    constructor(address _dacEntity, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        dacEntity = _dacEntity;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == dacEntity, "Only DAC");
        _mint(to, amount);
    }

    function stakeToDeal(address deal, uint256 amount) external {
        require(IDealCore(deal).isValidDeal(), "Invalid Deal");
        require(!IDealCore(deal).isApproved(), "Invalid Deal");
        
        _transfer(msg.sender, deal, amount);
        IDealCore(deal).onMPStaked(msg.sender, amount);
        emit Staked(msg.sender, deal, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == dacEntity, "Only DAC");
        _burn(from, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("MP tokens are non-transferable");
    }

    function approve(address deal, uint256 amount) public override returns (bool) {
        require(IDealCore(deal).isValidDeal(), "Invalid Deal");
        require(IDealCore(deal).isApproved(), "Invalid Deal");

        _approve(msg.sender, deal, amount);
        emit StakeRequested(msg.sender, deal, amount);

        return true;
    }
}