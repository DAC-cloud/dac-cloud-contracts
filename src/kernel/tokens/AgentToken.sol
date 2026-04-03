// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from"@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IAgentToken} from "../../interfaces/IAgentToken.sol";
import {IAssetController} from "../../interfaces/IAssetController.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "../interfaces/IDealCellAdapter.sol";
import {DACEventsLib} from "../../interfaces/DACEventsLib.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract AgentToken is IAgentToken, ERC20Upgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    address public dacCell;
    address public dealManager;
    address public assetController;

    event Staked(address indexed staker, address indexed deal, uint256 amount);
    event StakeRequested(address indexed staker, address indexed deal, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dacCell,
        string memory name, 
        string memory symbol
    ) external initializer {
        __ERC20_init(name, symbol);
        __AccessControl_init();

        dacCell = _dacCell;

        _grantRole(MINTER_ROLE, dacCell);
        _grantRole(BURNER_ROLE, dacCell);
    }

    function dacInit(
        address _dealManager,
        address _assetController
    ) external {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());

        dealManager = _dealManager;
        assetController = _assetController;

        _grantRole(MINTER_ROLE, _dealManager);
        _grantRole(BURNER_ROLE, _dealManager);
    }

    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _mint(to, amount);
    }

    function stakeToDeal(address dealCell, uint256 amount) external {
        require(qualifiedBalanceOf(msg.sender) >= amount, DACErrorsLib.NotTransferable());
        require(
            IDealManagerAdapter(dealManager).state(dealCell).id != 0, 
            DACErrorsLib.InvalidDealAddress()
        );
        
        require(IDealCell(dealCell).isValidDeal(), DACErrorsLib.InvalidDealAddress());
        require(!IDealCell(dealCell).isApproved(), DACErrorsLib.InvalidDealAddress());
        
        _transfer(msg.sender, dealCell, amount);
        IDealCellAdapter(dealCell).onAgentTokenStaked(msg.sender, amount);
        emit Staked(msg.sender, dealCell, amount);
    }

    function forceStakeToDeal(address staker, address dealCell, uint256 amount) external {
        require(msg.sender == dealManager, DACErrorsLib.NotAuthorized());
        require(qualifiedBalanceOf(staker) >= amount, DACErrorsLib.NotTransferable());
        require(
            IDealManagerAdapter(dealManager).state(dealCell).id != 0,
            DACErrorsLib.InvalidDealAddress()
        );
        require(IDealCell(dealCell).isValidDeal(), DACErrorsLib.InvalidDealAddress());
        require(!IDealCell(dealCell).isApproved(), DACErrorsLib.InvalidDealAddress());

        _transfer(staker, dealCell, amount);
        IDealCellAdapter(dealCell).onAgentTokenStaked(staker, amount);
        emit Staked(staker, dealCell, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(hasRole(BURNER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (assetController != address(0) && IAssetController(assetController).isAgentDistributor(msg.sender)) {
            IAssetController(assetController).handleAgentDistribution(msg.sender, to, amount);
            _transfer(msg.sender, to, amount);

            emit DACEventsLib.AgentTokenDistributed(dacCell, msg.sender, to, amount);
            return true;
        }

        require(
            IDealManagerAdapter(dealManager).state(msg.sender).id != 0, 
            DACErrorsLib.InvalidDealAddress()
        );
        
        require(IDealCell(msg.sender).isValidDeal(), DACErrorsLib.InvalidDealAddress());
        
        _transfer(msg.sender, to, amount);

        return true;
    }

    function approve(address deal, uint256 amount) public override returns (bool) {
        require(
            IDealManagerAdapter(dealManager).state(deal).id != 0, 
            DACErrorsLib.InvalidDealAddress()
        );
        
        require(IDealCell(deal).isValidDeal(), DACErrorsLib.InvalidDealAddress());
        require(IDealCell(deal).isApproved(), DACErrorsLib.InvalidDealAddress());

        _approve(msg.sender, deal, amount);

        emit StakeRequested(msg.sender, deal, amount);

        return true;
    }

    function qualifiedBalanceOf(address account) public view returns (uint256) {
        if (assetController != address(0) && IAssetController(assetController).isAgentDistributor(account)) {
            return 0;
        }

        return balanceOf(account);
    }
}
