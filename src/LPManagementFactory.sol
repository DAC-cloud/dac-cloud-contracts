// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LPManagementProposal.sol";

contract LPManagementFactory {
    function deployLPManagement(
        uint256 id,
        LPManagementType typ,
        address target,
        uint256 amountOrPercent,
        address dividendToken,
        address dac,
        address votingFactory,
        address token
    ) external returns (address) {
        LPManagementProposal prop = new LPManagementProposal(id, typ, target, amountOrPercent, dividendToken, dac, votingFactory, token);
        return address(prop);
    }
}
