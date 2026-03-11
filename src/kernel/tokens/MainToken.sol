// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from"@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from"@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {AccessControlUpgradeable} from"@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract MainToken is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    address public dacCell;
    uint256 public maxSupply;
    
    address public dealManager;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dacCell,
        uint256 _maxSupply,
        string memory name, 
        string memory symbol
    ) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC20Votes_init();
        __AccessControl_init();

        dacCell = _dacCell;
        maxSupply = _maxSupply;

        _grantRole(MINTER_ROLE, dacCell);
    }

    function dacInit(
        address _dealManager
    ) external {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());

        dealManager = _dealManager;
        _grantRole(MINTER_ROLE, _dealManager);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) private {
        IDealManagerAdapter(dealManager).onMainMove(from, to, amount);
    }

    function _beforeDelegate(address from, address to) private {
        IDealManagerAdapter(dealManager).onMainDelegate(from, to);
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, amount);
        _afterTokenTransfer(from, to, amount);
    }

    function _delegate(address from, address to) internal override {
        _beforeDelegate(from, to);
        super._delegate(from, to);
    }

    function nonces(address owner) public view virtual override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        require(totalSupply() + amount <= maxSupply, DACErrorsLib.MaxSupplyExceeded());
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