// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../DACCell.sol";

// library DACLibrary {
//     function getBytecode() public pure returns (bytes memory) {
//         return type(DACCell).creationCode;
//     }
// }

library DACDeployment {
    
    // Helper to pre-compute address (useful for frontend / agents)
    function predictDACAddress(
        bytes32 salt,
        address deployer,
        string calldata name,
        string calldata description,
        address governanceFactory
    ) public pure returns (address) {
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(DACCell).creationCode, abi.encode(
            name,
            description,
            governanceFactory
        )));

        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            bytecodeHash
        ));

        return address(uint160(uint256(hash)));
    }
}
