// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IDACFactory.sol";
import "./DACCell.sol";
import "./tokens/MainToken.sol";
import "./tokens/AgentToken.sol";

contract DACFactory is IDACFactory {
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

        // 1. Compute deterministic DAC address using CREATE2
        bytes memory constructorParams = abi.encode(
            config.name,
            config.description,
            config.defaultQuorum,
            governanceFactory
        );

        dacAddr = predictDACAddress(salt, constructorParams);

        // 2. Deploy LPToken with the predicted DAC address
        mainAddr = address(new MainToken(
            dacAddr, 
            config.mainTokenMaxSupply, 
            string.concat(config.name, " Token"), 
            config.symbol
        ));

        // 3. Deploy MPToken with the predicted DAC address
        agentAddr = address(new AgentToken(
            dacAddr, 
            string.concat(config.name, " Agent Token"), 
            string.concat(config.symbol, "A")
        ));

        // 4. Deploy DACEntity at the exact predicted address using CREATE2
        DACCell dac = new DACCell{salt: salt}(
            config.name,
            config.description,
            config.defaultQuorum,
            governanceFactory
        );

        require(address(dac) == dacAddr, "CREATE2 address mismatch");

        // 5. Call initialize on DACCell (two-phase)
        dac.initializeAfterDeployment(
            mainAddr,
            agentAddr,
            coreModuleFactory,
            config.dividendsEnabled
        );

        emit DACDeployed(dacAddr, mainAddr, agentAddr);

        dac.initializeRootCapitalCall(
            config.treasuryToken,
            config.founder,
            config.founderAllocation,
            config.founderCommitment
        );
    }

    // Helper to pre-compute address (useful for frontend / agents)
    function predictDACAddress(bytes32 salt, bytes memory constructorArgs) public view returns (address) {
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(DACCell).creationCode, constructorArgs));
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        ));
        return address(uint160(uint256(hash)));
    }
}