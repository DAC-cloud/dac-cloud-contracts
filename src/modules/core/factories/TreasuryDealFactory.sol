// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSProxy} from "../../../kernel/proxies/UUPSProxy.sol";
import {DealParams} from "../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../interfaces/modules/IDealFactory.sol";
import {TreasuryDeal} from "../deals/TreasuryDeal.sol";

contract TreasuryDealFactory is IDealFactory {
    address public immutable PERMIT2;
    address public immutable referenceImpl;

    constructor(address permit2) {
        referenceImpl = address(new TreasuryDeal());
        PERMIT2 = permit2;
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
            TreasuryDeal.initialize.selector,
            id,
            dac,
            params.governanceFactory,
            agentToken,
            mainToken,
            params.proposer,
            PERMIT2
        );

        dealAddr = address(new UUPSProxy(address(referenceImpl), initData));

        TreasuryDeal(dealAddr).joinDac(dealCell);
    }
}