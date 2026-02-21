// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./IDealCore.sol";

contract MPToken is ERC20 {
    uint256 public immutable maxSupply;
    address public immutable dacEntity;

    event Staked(address indexed staker, address indexed deal, uint256 amount);

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
        require(IDealCore(deal).isValidDeal(), "Invalid Deal");
        //todo: check in dac if the deal is valid

        _transfer(msg.sender, deal, amount);           // internal only
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
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("MP tokens are non-transferable");
    }
    function approve(address, uint256) public pure override returns (bool) {
        //todo allow to approve towards valid approved deal
        //  (after deal is active, approve is the only way to stake)
        revert("MP tokens are non-transferable");
    }
}