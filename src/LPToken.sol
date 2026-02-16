// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is ERC20 {
    address public dacEntity;

    constructor(string memory name_, string memory symbol_, address _dacEntity) ERC20(name_, symbol_) {
        dacEntity = _dacEntity;
    }

    function mint(address to, uint256 amount) external onlyDACEntity {
        _mint(to, amount);
    }

    modifier onlyDACEntity() {
        require(msg.sender == dacEntity, "Only DAC");
        _;
    }
}
