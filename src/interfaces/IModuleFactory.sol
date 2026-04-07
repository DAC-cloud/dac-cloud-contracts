// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DealParams, VotingConfig} from "./Structs.sol";

interface IModuleFactory {
    function moduleId() external view returns (bytes32);
    function moduleVersion() external view returns (uint32 major, uint32 minor, uint32 patch);
    function moduleManifestURI() external view returns (string memory);
    function supportedDealKinds() external view returns (bytes4[] memory);
    function supportedEvaluatorKinds() external view returns (bytes4[] memory);
    function supportsDealKind(bytes4 dealKind) external view returns (bool);
    function supportsDealRewardPool(bytes4 dealKind) external view returns (bool);

    // Cross-module compatibility: called on the deal's module
    function dealAcceptsEvaluator(bytes4 dealKind, bytes4 evaluatorKind, address evaluatorModule) external view returns (bool);

    // Cross-module compatibility: called on the evaluator's module
    function evaluatorAcceptsDeal(bytes4 evaluatorKind, bytes4 dealKind, address dealModule) external view returns (bool);

    function isActive() external view returns (bool);
    function safetyCheck(address deal) external view returns (bool);

    // Deploys only the Deal contract. DealCell is deployed by the kernel.
    function deployDeal(
        uint256 id,
        DealParams calldata params,
        address dac,
        address dealCell,
        VotingConfig calldata votingConfig
    ) external returns (address dealAddr);

    function deployEvaluator(
        address dac,
        uint256 id,
        address dealCell,
        DealParams calldata params,
        bytes4 evaluatorSelector,
        bytes calldata evaluatorConfig
    ) external returns (address evaluatorAddr);
}
