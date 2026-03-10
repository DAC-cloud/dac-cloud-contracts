// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from"@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from"@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {AccessControlUpgradeable} from"@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract StakedAgent is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    address public dealCell;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _deal,
        string memory name, 
        string memory symbol
    ) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC20Votes_init();
        __AccessControl_init();

        dealCell = _deal;

        _grantRole(MINTER_ROLE, dealCell);
        _grantRole(BURNER_ROLE, dealCell);
    }

    function transfer(address, uint256) public pure override returns (bool) { require(false, DACErrorsLib.NotTransferable()); return false; }
    function transferFrom(address, address, uint256) public pure override returns (bool) { require(false, DACErrorsLib.NotTransferable()); return false; }
    function approve(address, uint256) public pure override returns (bool) { require(false, DACErrorsLib.NotTransferable()); return false; }
    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) { super._update(from, to, amount); }
    function nonces(address owner) public view virtual override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) { return super.nonces(owner); }

    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(hasRole(BURNER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _burn(from, amount);
    }

    // ERC-6372 Clock with timestamp mode for OpenZeppelin Votes
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }
}