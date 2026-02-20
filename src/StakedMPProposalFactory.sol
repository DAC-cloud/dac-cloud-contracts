// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StakedMPProposal.sol";
import "./Interfaces.sol";

contract StakedMPProposalFactory {
    function deployProposal(
        uint256 id,
        StakedMPParams calldata params,
        address deal,
        address votingFactory,
        address token,
        VotingConfig calldata votingConfig
    ) external returns (address) {
        StakedMPParams memory proposalParams = params;
        VotingConfig memory _votingConfig = votingConfig;
        
        StakedMPProposal prop = new StakedMPProposal(
            id, 
            proposalParams, 
            deal,
            votingFactory, 
            token, 
            _votingConfig
        );
        return address(prop);
    }
}