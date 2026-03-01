// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACCell} from "../DACCell.sol";
import {UUPSProxy} from "../proxies/UUPSProxy.sol";

contract DACCellFactory {

    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new DACCell());
    }

    function deployDAC(
        bytes32 salt,
        string calldata name,
        string calldata description,
        address governanceFactory
    ) external returns (address dacAddr) {
        bytes memory initData = abi.encodeWithSelector(
            DACCell.initialize.selector,
            msg.sender,
            name,
            description,
            governanceFactory
        );

        dacAddr = address(new UUPSProxy{salt: salt}(address(referenceImpl), initData));
    }
}