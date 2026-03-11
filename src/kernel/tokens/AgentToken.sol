// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from"@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IAgentToken} from "../../interfaces/IAgentToken.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "../interfaces/IDealCellAdapter.sol";
import {DACErrorsLib} from "../../interfaces/DACErrorsLib.sol";

contract AgentToken is IAgentToken, ERC20Upgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    address public dacCell;
    address public dealManager;

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
        address _dealManager
    ) external {
        require(msg.sender == dacCell, DACErrorsLib.NotAuthorized());

        dealManager = _dealManager;

        _grantRole(MINTER_ROLE, _dealManager);
        _grantRole(BURNER_ROLE, _dealManager);
    }

    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _mint(to, amount);
    }

    function stakeToDeal(address dealCell, uint256 amount) external {
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

    function burnFrom(address from, uint256 amount) external {
        require(hasRole(BURNER_ROLE, msg.sender), DACErrorsLib.NotAuthorized());

        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
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
}