// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSProxy} from "../../../kernel/proxies/UUPSProxy.sol";
import {DealParams} from "../../../interfaces/Structs.sol";
import {IDealFactory} from "../../../interfaces/modules/IDealFactory.sol";
import {TreasuryDeal} from "../deals/TreasuryDeal.sol";
import {Permit2TreasuryFactory} from "../deals/Permit2Treasury.sol";

contract TreasuryDealFactory is IDealFactory {
    address public immutable permit2VaultFactory;
    address public immutable referenceImpl;

    constructor(address permit2) {
        referenceImpl = address(new TreasuryDeal());
        permit2VaultFactory = address(new Permit2TreasuryFactory(permit2));
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
            permit2VaultFactory
        );

        dealAddr = address(new UUPSProxy(address(referenceImpl), initData));

        TreasuryDeal(dealAddr).joinDac(dealCell);
    }
}