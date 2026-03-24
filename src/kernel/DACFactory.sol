// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DACConfig, ExistingDACConfig} from "../interfaces/Structs.sol";
import {IDACFactory} from "../interfaces/IDACFactory.sol";
import {DACCellFactory} from "./factories/DACCellFactory.sol";
import {DACCell} from "./DACCell.sol";
import {DACDeployment} from "./libraries/DACDeployment.sol";
import {DACEventsLib} from "../interfaces/DACEventsLib.sol";
import {MainTokenFactory, AgentTokenFactory} from "./tokens/factories/TokenFactories.sol";
import {WrappedMainTokenFactory} from "./tokens/factories/WrappedMainTokenFactory.sol";
import {GovernanceOracleFactory} from "./governance/factories/GovernanceOracleFactory.sol";

contract DACFactory is IDACFactory {
    error Create2Failed();
    error SleepingCellNotFound();
    error DNAMismatch();

    address public mainTokenFactory;
    address public agentTokenFactory;

    address public cellFactory;
    address public managerFactory;
    address public moduleRegistryFactory;
    address public assetControllerFactory;
    address public governanceFactory;
    address public governanceSchemaFactory;
    address public existingAssetControllerFactory;
    address public hybridProposalFactory;
    address public hybridGovernanceSchemaFactory;
    address public wrappedMainTokenFactory;
    address public governanceOracleFactory;
    address public coreModuleFactory;
    
    mapping(bytes32 => bytes32) private sleepingCells;

    constructor(address[9] memory coreDeps, address[5] memory hybridDeps) {
        mainTokenFactory = coreDeps[0];
        agentTokenFactory = coreDeps[1];
        cellFactory = coreDeps[2];
        managerFactory = coreDeps[3];
        moduleRegistryFactory = coreDeps[4];
        assetControllerFactory = coreDeps[5];
        governanceFactory = coreDeps[6];
        governanceSchemaFactory = coreDeps[7];
        coreModuleFactory = coreDeps[8];

        existingAssetControllerFactory = hybridDeps[0];
        hybridProposalFactory = hybridDeps[1];
        hybridGovernanceSchemaFactory = hybridDeps[2];
        wrappedMainTokenFactory = hybridDeps[3];
        governanceOracleFactory = hybridDeps[4];
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
            _initializeDAC(dac, config, mainAddr, agentAddr);
        }
        else {
            bytes32 deferInitCell = keccak256(abi.encode(deferBirthRole, address(dac)));
            bytes32 deferInitCalldata = keccak256(abi.encode(config, mainAddr, agentAddr));

            sleepingCells[deferInitCell] = deferInitCalldata;
        }

        emit DACEventsLib.DACDeployed(dacAddr, mainAddr, agentAddr, (deferBirthRole == address(0)));
    }

    function deployExistingTokenDAC(
        bytes calldata encodedConfig,
        bytes32 salt
    ) external returns (
        address dacAddr,
        address wrappedMainTokenAddr,
        address agentTokenAddr,
        address governanceOracleAddr
    ) {
        ExistingDACConfig memory config = abi.decode(encodedConfig, (ExistingDACConfig));

        require(config.underlyingToken != address(0));
        require(config.oracleAdmin != address(0));

        dacAddr = _predictExistingDACAddress(config, salt);
        wrappedMainTokenAddr = _deployWrappedMainToken(config, dacAddr);
        agentTokenAddr = _deployAgentToken(config, dacAddr);
        governanceOracleAddr = _deployGovernanceOracle(config);

        DACCell dac = _deployExistingDACCell(config, salt);

        require(address(dac) == dacAddr, Create2Failed());

        _initializeExistingDAC(dac, config, wrappedMainTokenAddr, agentTokenAddr, governanceOracleAddr);

        emit DACEventsLib.DACDeployed(dacAddr, wrappedMainTokenAddr, agentTokenAddr, true);
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

        _initializeDAC(DACCell(dacCell), config, mainTokenAddr, agentTokenAddr);
    }

    function _initializeDAC(
        DACCell dac,
        DACConfig calldata config,
        address mainTokenAddr,
        address agentTokenAddr
    ) internal {
        dac.initializeAfterDeployment(
            mainTokenAddr,
            agentTokenAddr,
            managerFactory,
            moduleRegistryFactory,
            assetControllerFactory,
            governanceSchemaFactory,
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

    function _initializeExistingDAC(
        DACCell dac,
        ExistingDACConfig memory config,
        address wrappedMainTokenAddr,
        address agentTokenAddr,
        address governanceOracleAddr
    ) internal {
        dac.initializeExistingTokenAfterDeployment(
            wrappedMainTokenAddr,
            agentTokenAddr,
            managerFactory,
            moduleRegistryFactory,
            existingAssetControllerFactory,
            hybridGovernanceSchemaFactory,
            governanceOracleAddr,
            coreModuleFactory,
            config
        );
    }

    function _predictExistingDACAddress(
        ExistingDACConfig memory config,
        bytes32 salt
    ) internal view returns (address dacAddr) {
        dacAddr = DACDeployment.predictDACAddress(
            salt,
            address(this),
            DACCellFactory(cellFactory).referenceImpl(),
            cellFactory,
            config.name,
            config.description,
            hybridProposalFactory
        );
    }

    function _deployWrappedMainToken(
        ExistingDACConfig memory config,
        address dacAddr
    ) internal returns (address wrappedMainTokenAddr) {
        wrappedMainTokenAddr = WrappedMainTokenFactory(wrappedMainTokenFactory).deployWrappedMainToken(
            config.underlyingToken,
            string.concat("Wrapped ", config.name, " Token"),
            string.concat("w", config.symbol),
            dacAddr
        );
    }

    function _deployAgentToken(
        ExistingDACConfig memory config,
        address dacAddr
    ) internal returns (address agentTokenAddr) {
        agentTokenAddr = AgentTokenFactory(agentTokenFactory).deployAgentToken(
            dacAddr,
            string.concat(config.name, " Agent Token"),
            string.concat(config.symbol, "A")
        );
    }

    function _deployGovernanceOracle(
        ExistingDACConfig memory config
    ) internal returns (address governanceOracleAddr) {
        governanceOracleAddr = GovernanceOracleFactory(governanceOracleFactory).deployGovernanceOracle(
            config.oracleAdmin,
            config.initialOraclePublisher
        );
    }

    function _deployExistingDACCell(
        ExistingDACConfig memory config,
        bytes32 salt
    ) internal returns (DACCell dac) {
        dac = DACCell(
            DACCellFactory(cellFactory).deployDAC(
                salt,
                config.name,
                config.description,
                hybridProposalFactory
            )
        );
    }
}
