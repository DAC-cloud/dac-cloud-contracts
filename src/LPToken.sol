// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is ERC20 {
    address public immutable dacEntity;

    uint256 public immutable maxSupply;

    constructor(string memory name_, string memory symbol_, address _dacEntity, uint256 _maxSupply) ERC20(name_, symbol_) {
        dacEntity = _dacEntity;
        maxSupply = _maxSupply;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == dacEntity, "Only DAC");
        require(totalSupply() + amount <= maxSupply, "Exceeds max");
        _mint(to, amount);
    }
}