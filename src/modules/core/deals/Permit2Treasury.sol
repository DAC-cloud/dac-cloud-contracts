// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "../../../lib/IPermit2.sol";
import {IClock} from "../../../lib/IClock.sol";
import {IVotes} from "../../../lib/IVotes.sol";
import {TreasurySpendAllowance} from "../interfaces/Structs.sol";
import {UUPSProxy} from "../../../kernel/proxies/UUPSProxy.sol";

contract Permit2Treasury is ReentrancyGuard, IClock, Initializable {
    using SafeERC20 for IERC20;

    error NotAuthorized();

    error ReceiveNotApproved();

    error SpendNotApproved();
    error InvalidDealSize();
    error InvalidDealTimeBounds();

    error InvalidTransfer();

    address public treasuryDeal;
    IPermit2 public permit2;

    mapping(bytes32 => uint256) public approvedAgents; // calldataHash(agent, token, source) => totalAmount
    mapping(bytes32 => TreasurySpendAllowance) public agentAllowance; // calldataHash(agent, token, destination) => allowance

    event SpendApproved(address token, address destination, uint256 amount);

    event DirectSpend(address token, address destination, uint256 amount);
    
    event AgentReceiveApproved(address indexed agent, address token, address source, uint256 amount);
    event AgentSpendApproved(address indexed agent, address token, address source, uint256 amount);

    event AgentRevoked(address indexed agent, address token, address counterparty);

    event AgentSpendReceipt(address indexed agent, address token, address destination, uint256 amount);
    event AgentReceiveReceipt(address indexed agent, address token, address source, uint256 amount);

    event CapitalReturned(address token, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _treasuryDeal, 
        address _permit2
    ) external initializer {
        treasuryDeal = _treasuryDeal;
        permit2 = IPermit2(_permit2);
    }

    // ERC-6372 Clock with timestamp mode
    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure virtual override returns (string memory) {
        return "mode=timestamp";
    }

    // Called by TreasuryDeal after staked-agents quorum approves a spend allowance
    function approveSpend(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external onlyDeal nonReentrant {
        // Approving the whole balance of the token to permit2
        IERC20(token).forceApprove(address(permit2), type(uint160).max);

        // On-chain Permit2 approval (no signature needed to spend)
        // to govern single spend transactions by routers / service providers.
        permit2.approve(token, spender, amount, expiration);

        emit SpendApproved(token, spender, amount);
    }

    // Called by TreasuryDeal after staked-agents quorum approves a direct spend
    function directSpend(
        address token,
        address destination,
        uint160 amount
    ) external onlyDeal nonReentrant {
        IERC20(token).safeTransfer(destination, amount);

        emit DirectSpend(token, destination, amount);
    }

    // Called by TreasuryDeal after staked-agents quorum approves a spend allowance towards agent.
    //  `destination` provides fine grained control related to counterparties;
    //  `destination` = address(0x0) means wildcard allowance - allowing to receive or send towards any address
    function approveSpendAllowance(
        address agent,
        address token,
        address destination,
        TreasurySpendAllowance memory allowance
    ) external onlyDeal {
        bytes32 calldataHash = keccak256(abi.encode(agent, token, destination));
        agentAllowance[calldataHash] = allowance;

        emit AgentSpendApproved(agent, token, destination, allowance.totalAmount);
    }

    // Called by TreasuryDeal after staked-agents quorum approves a spend allowance towards agent
    function rewokeAgent(
        address agent,
        address token,
        address counterparty
    ) external onlyDeal {
        bytes32 calldataHash = keccak256(abi.encode(agent, token, counterparty));

        delete(agentAllowance[calldataHash]);
        delete(approvedAgents[calldataHash]);

        emit AgentRevoked(agent, token, counterparty);
    }

    // Called by TreasuryDeal after staked-agents quorum approves an agent to receive funds
    function approveReceive(
        address agent,
        address source,
        address token,
        uint160 amount
    ) external onlyDeal {
        bytes32 calldataHash = keccak256(abi.encode(agent, token, source));
        approvedAgents[calldataHash] = amount;

        emit AgentReceiveApproved(agent, token, source, amount);
    }

    function delegateVotes(address token, address delegatee) external onlyDeal {
        IVotes(token).delegate(delegatee);
    }

    // Called by an assigned agent after approval
    //  (e.g. our service executes gasless x402 payment receive)
    function executeReceivePermit2(
        address token,
        address source,
        uint160 amount
    ) external nonReentrant {
        bytes32 calldataHash = keccak256(abi.encode(msg.sender, token, source));
        
        if (approvedAgents[calldataHash] == 0) {
            // If specific destination allowance not exists,
            //  switching to wildcard allowance
            calldataHash = keccak256(abi.encode(msg.sender, token, address(0)));
        }

        require(approvedAgents[calldataHash] >= amount, ReceiveNotApproved());

        approvedAgents[calldataHash] -= amount;

        // Execute transfer to treasury via Permit2 (uses the on-chain approval)
        permit2.transferFrom(source, address(this), amount, token);

        emit AgentReceiveReceipt(msg.sender, token, source, amount);
    }

    function executeReceivePermit2Signature(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address source,
        bytes calldata signature
    ) external nonReentrant {
        require(transferDetails.to == address(this), InvalidTransfer());
        
        bytes32 calldataHash = keccak256(abi.encode(msg.sender, permit.token, source));

        if (approvedAgents[calldataHash] == 0) {
            // If specific destination allowance not exists,
            //  switching to wildcard allowance
            calldataHash = keccak256(abi.encode(msg.sender, permit.token, address(0)));
        }

        require(approvedAgents[calldataHash] >= transferDetails.requestedAmount, ReceiveNotApproved());
        
        approvedAgents[calldataHash] -= transferDetails.requestedAmount;

        permit2.permitTransferFrom(permit, transferDetails, source, signature);

        emit AgentReceiveReceipt(msg.sender, permit.token, source, transferDetails.requestedAmount);
    }

    function executeAgentSpend(address token, address destination, uint160 amount) external nonReentrant {
        bytes32 calldataHash = keccak256(abi.encode(msg.sender, token, destination));

        if (agentAllowance[calldataHash].totalAmount == 0) {
            // If specific destination allowance not exists,
            //  switching to wildcard allowance
            calldataHash = keccak256(abi.encode(msg.sender, token, address(0)));
        }

        require(agentAllowance[calldataHash].totalAmount >= amount, SpendNotApproved());
        require(agentAllowance[calldataHash].singleTxAmount >= amount, InvalidDealSize());
        require(agentAllowance[calldataHash].clockLimit < clock(), InvalidDealTimeBounds());

        agentAllowance[calldataHash].totalAmount -= amount;
        agentAllowance[calldataHash].clockLimit = clock() + agentAllowance[calldataHash].duration;

        IERC20(token).safeTransfer(destination, amount);

        emit AgentSpendReceipt(msg.sender, token, destination, amount);
    }

    // For returning capital to Deal
    function returnCapitalToDeal(address token, uint256 balance) external onlyDeal nonReentrant {
        IERC20(token).safeTransfer(treasuryDeal, balance);
        emit CapitalReturned(token, balance);
    }

    modifier onlyDeal {
        _onlyDeal();
        _;
    }

    function _onlyDeal() internal view {
        require(msg.sender == treasuryDeal, NotAuthorized());
    }
}

contract Permit2TreasuryFactory {

    address private referenceImpl;
    address private permit2;

    constructor(
        address _permit2
    ) {
        referenceImpl = address(new Permit2Treasury());
        
        permit2 = _permit2;
    }

    function deployPermit2Treasury(
        address deal
    ) public returns (Permit2Treasury) {
        bytes memory initData = abi.encodeWithSelector(
            Permit2Treasury.initialize.selector,
            deal,
            permit2
        );

        return Permit2Treasury(address(new UUPSProxy(address(referenceImpl), initData)));
    }
}
