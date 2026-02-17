// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LPManagementProposal.sol";
import "./Interfaces.sol";

contract LPManagementFactory {
    function deployLPManagement(
        uint256 id,
        LPMParams calldata params,
        address dac,
        address votingFactory,
        address token
    ) external returns (address) {
        LPMParams memory proposalParams = params;
        LPManagementProposal prop = new LPManagementProposal(id, proposalParams, dac, votingFactory, token);
        return address(prop);
    }
}