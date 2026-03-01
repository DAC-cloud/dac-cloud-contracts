// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from"@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IDACCellAdapter} from "../interfaces/IDACCellAdapter.sol";
import {IDealCell} from "../../interfaces/IDealCell.sol";
import {IDealManagerAdapter} from "../interfaces/IDealManagerAdapter.sol";
import {IDealCellAdapter} from "../interfaces/IDealCellAdapter.sol";

contract AgentToken is ERC20Upgradeable, AccessControlUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    error NotAuthorized();
    error InvalidDeal();
    error NotTransferable();

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
        dealManager = _dealManager;

        _grantRole(MINTER_ROLE, _dealManager);
        _grantRole(BURNER_ROLE, _dealManager);
    }

    function mint(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), NotAuthorized());

        _mint(to, amount);
    }

    function stakeToDeal(address deal, uint256 amount) external {
        require(
            IDealManagerAdapter(dealManager).state(deal).id != 0, 
            InvalidDeal()
        );
        
        require(IDealCell(deal).isValidDeal(), InvalidDeal());
        require(!IDealCell(deal).isApproved(), InvalidDeal());
        
        _transfer(msg.sender, deal, amount);
        IDealCellAdapter(deal).onAgentTokenStaked(msg.sender, amount);
        emit Staked(msg.sender, deal, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(hasRole(BURNER_ROLE, msg.sender), NotAuthorized());

        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(
            IDealManagerAdapter(dealManager).state(msg.sender).id != 0, 
            InvalidDeal()
        );
        
        require(IDealCell(msg.sender).isValidDeal(), InvalidDeal());
        require(!IDealCell(msg.sender).isApproved(), InvalidDeal());
        
        _transfer(msg.sender, to, amount);

        return true;
    }

    function approve(address deal, uint256 amount) public override returns (bool) {
        require(
            IDealManagerAdapter(dealManager).state(deal).id != 0, 
            InvalidDeal()
        );
        
        require(IDealCell(deal).isValidDeal(), InvalidDeal());
        require(IDealCell(deal).isApproved(), InvalidDeal());

        _approve(msg.sender, deal, amount);

        emit StakeRequested(msg.sender, deal, amount);

        return true;
    }
}