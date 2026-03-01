// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IClock} from "../../lib/IClock.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IDACCellAdapter} from "../interfaces/IDACCellAdapter.sol";

contract MainToken is ERC20, ERC20Permit, ERC20Votes {
    error NotAuthorized();
    error MaxSupplyExceeded();

    address public immutable dacCell;

    uint256 public immutable maxSupply;

    constructor(
        address _dacCell, 
        uint256 _maxSupply, 
        string memory name_, 
        string memory symbol_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        dacCell = _dacCell;
        maxSupply = _maxSupply;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) private {
        IDealManagerAdapter(IDACCellAdapter(dacCell).getDealManager()).onMainMove(from, to, amount);
    }

    function _beforeDelegate(address from, address to) private {
        IDealManagerAdapter(IDACCellAdapter(dacCell).getDealManager()).onMainDelegate(from, to);
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
        _afterTokenTransfer(from, to, amount);
    }

    function _delegate(address from, address to) internal override {
        _beforeDelegate(from, to);
        super._delegate(from, to);
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == dacCell, NotAuthorized());
        require(totalSupply() + amount <= maxSupply, MaxSupplyExceeded());
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ERC-6372 Clock with timestamp mode for OpenZeppelin Votes
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }
}