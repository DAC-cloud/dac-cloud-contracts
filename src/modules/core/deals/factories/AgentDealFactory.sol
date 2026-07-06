// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSProxy} from "../../../../kernel/proxies/UUPSProxy.sol";
import {DealParams} from "../../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../../interfaces/modules/IDealFactory.sol";
import {AgentDeal} from "../AgentDeal.sol";

contract AgentDealFactory is IDealFactory {

    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new AgentDeal());
    }

    function deployDeal(
        uint256 id,
        address dealCell,
        DealParams calldata params,
        address dac,
        address agentToken,
        address mainToken
    ) external returns (address dealAddr) {
        bytes memory initData = abi.encodeWithSelector(
            AgentDeal.initialize.selector,
            id,
            dac,
            params.governanceFactory,
            agentToken,
            mainToken,
            params.proposer,
            address(this)
        );

        dealAddr = address(new UUPSProxy(address(referenceImpl), initData));

        AgentDeal(dealAddr).joinDac(dealCell);
    }
}
