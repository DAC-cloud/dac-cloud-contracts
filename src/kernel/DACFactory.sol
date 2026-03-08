// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACConfig} from "../interfaces/Structs.sol";
import {IDACFactory} from "../interfaces/IDACFactory.sol";
import {DACCellFactory} from "./factories/DACCellFactory.sol";
import {DACCell} from "./DACCell.sol";
import {DACDeployment} from "./libraries/DACDeployment.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";
import {MainTokenFactory, AgentTokenFactory} from "./tokens/factories/TokenFactories.sol";

contract DACFactory is IDACFactory {
    error Create2Failed();
    error SleepingCellNotFound();
    error DNAMismatch();

    address public mainTokenFactory;
    address public agentTokenFactory;

    address public cellFactory;
    address public managerFactory;
    address public governanceFactory;
    address public coreModuleFactory;
    
    mapping(bytes32 => bytes32) private sleepingCells;

    constructor(
        address _mainTokenFactory,
        address _agentTokenFactory,
        address _cellFactory,
        address _managerFactory,
        address _governanceFactory,
        address _coreModuleFactory
    ) {
        mainTokenFactory = _mainTokenFactory;
        agentTokenFactory = _agentTokenFactory;
        cellFactory = _cellFactory;
        managerFactory = _managerFactory;
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
            DACCellFactory(cellFactory).referenceImpl(),
            cellFactory,
            config.name,
            config.description,
            governanceFactory
        );

        mainAddr = MainTokenFactory(mainTokenFactory).deployMainToken(
            dacAddr, 
            config.mainTokenMaxSupply, 
            string.concat(config.name, " Token"), 
            config.symbol
        );

        agentAddr = AgentTokenFactory(agentTokenFactory).deployAgentToken(
            dacAddr, 
            string.concat(config.name, " Agent Token"), 
            string.concat(config.symbol, "A")
        );

        DACCell dac = DACCell(
            DACCellFactory(cellFactory).deployDAC(
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
                managerFactory,
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

        emit DACEventsLib.DACDeployed(dacAddr, mainAddr, agentAddr, (deferBirthRole == address(0)));
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
            managerFactory,
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