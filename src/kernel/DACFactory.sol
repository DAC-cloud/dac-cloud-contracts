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
    error SleepingCellNotFound();
    error DNAMismatch();

    address public governanceFactory;
    address public coreModuleFactory;
    
    mapping(bytes32 => bytes32) private sleepingCells;

    event DACDeployed(address indexed dac, address mainToken, address agentToken, bool init);

    constructor(
        address _governanceFactory,
        address _coreModuleFactory
    ) {
        governanceFactory = _governanceFactory;
        coreModuleFactory = _coreModuleFactory;
    }

    function deployDAC(
        DACConfig calldata config,
        bytes32 salt,
        address deferBirthRole
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

        if (deferBirthRole == address(0)) {
            dac.initializeAfterDeployment(
                mainAddr,
                agentAddr,
                coreModuleFactory,
                config.dividendsEnabled,
                config.defaultQuorum
            );

            dac.initializeRootCapitalCall(
                config.treasuryToken,
                config.founder,
                config.founderAllocation,
                config.founderCommitment
            );
        }
        else {
            bytes32 deferInitCell = keccak256(abi.encode(deferBirthRole, address(dac)));
            bytes32 deferInitCalldata = keccak256(abi.encode(config, mainAddr, agentAddr));

            sleepingCells[deferInitCell] = deferInitCalldata;
        }

        emit DACDeployed(dacAddr, mainAddr, agentAddr, (deferBirthRole == address(0)));
    }

    function startDAC(
        address dacCell,
        DACConfig calldata config,
        address mainTokenAddr,
        address agentTokenAddr
    ) external {
        bytes32 deferInitCell = keccak256(abi.encode(msg.sender, dacCell));
        require(sleepingCells[deferInitCell] != bytes32(0), SleepingCellNotFound());

        bytes32 deferInitCalldata = keccak256(abi.encode(config, mainTokenAddr, agentTokenAddr));
        require(sleepingCells[deferInitCell] == deferInitCalldata, DNAMismatch());

        DACCell(dacCell).initializeAfterDeployment(
            mainTokenAddr,
            agentTokenAddr,
            coreModuleFactory,
            config.dividendsEnabled,
            config.defaultQuorum
        );

        DACCell(dacCell).initializeRootCapitalCall(
            config.treasuryToken,
            config.founder,
            config.founderAllocation,
            config.founderCommitment
        );
    }
}