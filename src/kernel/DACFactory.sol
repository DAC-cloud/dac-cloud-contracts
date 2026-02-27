// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACConfig} from "../interfaces/Structs.sol";
import {IDACFactory} from "../interfaces/IDACFactory.sol";
import {DACCellFactory} from "./factories/DACCellFactory.sol";
import {DACCell} from "./DACCell.sol";
import {DACDeployment} from "./libraries/DACDeployment.sol";
import {MainTokenLib, AgentTokenLib} from "./tokens/factories/TokenFactories.sol";

contract DACFactory is IDACFactory {
    error Create2Failed();

    address public governanceFactory;
    address public coreModuleFactory;
    
    event DACDeployed(address indexed dac, address mainToken, address agentToken);

    constructor(
        address _governanceFactory,
        address _coreModuleFactory
    ) {
        governanceFactory = _governanceFactory;
        coreModuleFactory = _coreModuleFactory;
    }

    function deployDAC(
        DACConfig calldata config,
        bytes32 salt
    ) external returns (address dacAddr, address mainAddr, address agentAddr) {
        require(config.mainTokenMaxSupply > config.founderAllocation);

        dacAddr = DACDeployment.predictDACAddress(
            salt,
            address(this),
            config.name,
            config.description,
            governanceFactory
        );

        mainAddr = MainTokenLib.deployMainToken(
            dacAddr, 
            config.mainTokenMaxSupply, 
            string.concat(config.name, " Token"), 
            config.symbol
        );

        agentAddr = AgentTokenLib.deployAgentToken(
            dacAddr, 
            string.concat(config.name, " Agent Token"), 
            string.concat(config.symbol, "A")
        );

        DACCell dac = DACCell(
            DACCellFactory.deployDAC(
                salt, 
                config.name,
                config.description,
                governanceFactory
            )
        );

        require(address(dac) == dacAddr, Create2Failed());

        dac.initializeAfterDeployment(
            mainAddr,
            agentAddr,
            coreModuleFactory,
            config.dividendsEnabled,
            config.defaultQuorum
        );

        emit DACDeployed(dacAddr, mainAddr, agentAddr);

        dac.initializeRootCapitalCall(
            config.treasuryToken,
            config.founder,
            config.founderAllocation,
            config.founderCommitment
        );
    }
}