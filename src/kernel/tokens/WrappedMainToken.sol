// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";

contract WrappedMainToken is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable {
    IERC20 public underlying;
    address public admin;
    address public controller;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _underlying, string memory name_, string memory symbol_, address _admin) external initializer {
        require(_underlying != address(0), DACErrorsLib.NotAllowed());
        require(_admin != address(0), DACErrorsLib.NotAllowed());

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Votes_init();

        underlying = IERC20(_underlying);
        admin = _admin;
    }

    function setController(address _controller) external onlyAdmin {
        require(_controller != address(0), DACErrorsLib.NotAllowed());
        controller = _controller;
    }

    function wrap(uint256 amount) external returns (uint256 wrappedAmount) {
        return wrapTo(msg.sender, amount);
    }

    function wrapTo(address recipient, uint256 amount) public returns (uint256 wrappedAmount) {
        require(recipient != address(0), DACErrorsLib.NotAllowed());
        require(amount > 0, DACErrorsLib.NotAllowed());
        require(underlying.transferFrom(msg.sender, address(this), amount), DACErrorsLib.TransferFailed());

        _mint(recipient, amount);
        _autoDelegate(recipient);

        emit DACEventsLib.Wrapped(msg.sender, recipient, amount);

        return amount;
    }

    function unwrap(uint256 amount) external returns (uint256 underlyingAmount) {
        return unwrapTo(msg.sender, amount);
    }

    function unwrapTo(address recipient, uint256 amount) public returns (uint256 underlyingAmount) {
        require(recipient != address(0), DACErrorsLib.NotAllowed());
        require(amount > 0, DACErrorsLib.NotAllowed());

        _burn(msg.sender, amount);
        require(underlying.transfer(recipient, amount), DACErrorsLib.TransferFailed());

        emit DACEventsLib.Unwrapped(msg.sender, recipient, amount);

        return amount;
    }

    function _autoDelegate(address recipient) internal {
        if (delegates(recipient) == address(0) && balanceOf(recipient) > 0) {
            _delegate(recipient, recipient);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal {
        if (controller != address(0)) {
            IAssetController(controller).onMainMove(from, to, amount);
        }
    }

    function _beforeDelegate(address from, address to) internal view {
        if (controller != address(0)) {
            IAssetController(controller).onMainDelegate(from, to);
        }
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, amount);
        _afterTokenTransfer(from, to, amount);
    }

    function _delegate(address from, address to) internal override {
        _beforeDelegate(from, to);
        super._delegate(from, to);
    }

    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, DACErrorsLib.NotAuthorized());
        _;
    }
}
