// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IDACFactory.sol";
import "./DACCell.sol";
import "./tokens/LPToken.sol";
import "./tokens/MPToken.sol";

contract DACFactory is IDACFactory {
    address public governanceFactory;
    address public coreModuleFactory;
    
    event DACDeployed(address indexed dac, address lpToken, address mpToken);

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
    ) external returns (address dacAddr, address lpAddr, address mpAddr) {
        require(config.lpMaxSupply > config.founderLP);

        // 1. Compute deterministic DAC address using CREATE2
        bytes memory constructorParams = abi.encode(
            config.name,
            config.description,
            config.defaultQuorum,
            governanceFactory
        );

        dacAddr = predictDACAddress(salt, constructorParams);

        // 2. Deploy LPToken with the predicted DAC address
        lpAddr = address(new LPToken(
            dacAddr, 
            config.lpMaxSupply, 
            string.concat(config.name, " Limited Partner"), 
            string.concat(config.symbol, "L")
        ));

        // 3. Deploy MPToken with the predicted DAC address
        mpAddr = address(new MPToken(
            dacAddr, 
            string.concat(config.name, " Managing Partner"), 
            string.concat(config.symbol, "M")
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
            lpAddr,
            mpAddr,
            coreModuleFactory
        );

        emit DACDeployed(dacAddr, lpAddr, mpAddr);

        dac.initializeRootCapitalCall(
            config.treasuryToken,
            config.founder,
            config.founderLP,
            config.founderCommitment
        );

        return (dacAddr, lpAddr, mpAddr);
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