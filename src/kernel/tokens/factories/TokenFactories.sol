// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentToken} from "../AgentToken.sol";
import {MainToken} from "../MainToken.sol";
import {StakedAgent} from "../StakedAgent.sol";

library MainTokenLib {
    function deployMainToken(
        address dac,
        uint256 maxSupply,
        string memory name,
        string memory symbol
    ) public returns (address mainToken) {
        mainToken = address(
            new MainToken(
                dac,
                maxSupply,
                name,
                symbol
            )
        );
    }
}

library AgentTokenLib {
    function deployAgentToken(
        address dac,
        string memory name,
        string memory symbol
    ) public returns (address agentToken) {
        agentToken = address(
            new AgentToken(
                dac,
                name,
                symbol
            )
        );
    }
}

library StakedAgentLib {
    function deployStakedAgentToken(
        address deal,
        string memory name,
        string memory symbol
    ) public returns (address stakedAgentToken) {
        stakedAgentToken = address(
            new StakedAgent(
                deal,
                name,
                symbol
            )
        );
    }
}