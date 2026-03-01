// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealCell} from "../DealCell.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract DealCellFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new DealCell());
    }

    function deployCell(
        uint256 id,
        address dac,
        address _dealManager,
        address governanceFactory,
        address agentToken,
        address mainToken,
        address proposer
    ) public returns (address cellAddr) {
        bytes memory initData = abi.encodeWithSelector(
            DealCell.initialize.selector,
            id,
            DealCell.DACAddresses({
                _deployer: msg.sender,
                _dac: dac,
                _dealManager: _dealManager,
                _governanceFactory: governanceFactory,
                _agentToken: agentToken,
                _mainToken: mainToken,
                _proposer: proposer
            })
        );

        cellAddr = address(new UUPSProxy(address(referenceImpl), initData));
    }
}