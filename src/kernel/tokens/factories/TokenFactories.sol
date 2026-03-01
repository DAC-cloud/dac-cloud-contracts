// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentToken} from "../AgentToken.sol";
import {MainToken} from "../MainToken.sol";
import {StakedAgent} from "../StakedAgent.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract MainTokenFactory {

    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new MainToken());
    }

    function deployMainToken(
        address dac,
        uint256 maxSupply,
        string memory name,
        string memory symbol
    ) public returns (address mainToken) {
        bytes memory initData = abi.encodeWithSelector(
            MainToken.initialize.selector,
            dac,
            maxSupply,
            name,
            symbol
        );

        mainToken = address(new UUPSProxy(address(referenceImpl), initData));
    }
}

contract AgentTokenFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new AgentToken());
    }

    function deployAgentToken(
        address dac,
        string memory name,
        string memory symbol
    ) public returns (address agentToken) {
        bytes memory initData = abi.encodeWithSelector(
            AgentToken.initialize.selector,
            dac,
            name,
            symbol
        );

        agentToken = address(new UUPSProxy(address(referenceImpl), initData));
    }
}

contract StakedAgentFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new StakedAgent());
    }

    function deployStakedAgentToken(
        address deal,
        string memory name,
        string memory symbol
    ) public returns (address stakedAgentToken) {
        bytes memory initData = abi.encodeWithSelector(
            StakedAgent.initialize.selector,
            deal,
            name,
            symbol
        );

        stakedAgentToken = address(new UUPSProxy(address(referenceImpl), initData));
    }
}