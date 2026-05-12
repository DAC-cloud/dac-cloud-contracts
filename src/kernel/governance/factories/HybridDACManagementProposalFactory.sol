// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalParams} from "../../../interfaces/Structs.sol";
import {GovernanceStrategyConfig} from "../../../interfaces/GovernanceStructs.sol";
import {HybridDACManagementProposal} from "../HybridDACManagementProposal.sol";
import {UUPSProxy} from "../../proxies/UUPSProxy.sol";

contract HybridDACManagementProposalFactory {
    address public immutable referenceImpl;

    constructor() {
        referenceImpl = address(new HybridDACManagementProposal());
    }

    function deployProposal(
        uint256 id,
        address dacCell,
        address wrappedToken,
        address governanceOracle,
        address assetControllerAddr,
        ProposalParams memory params,
        GovernanceStrategyConfig memory strategy,
        bool highQuorum,
        bool blockingEnabled
    ) external returns (address proposal) {
        // The caller (HybridGovernanceSchema) owns the proposal's consume-and-act
        // lifecycle, so bind it as the proposal's only authorized executor.
        bytes memory initData = abi.encodeWithSelector(
            HybridDACManagementProposal.initialize.selector,
            id,
            dacCell,
            msg.sender,
            wrappedToken,
            governanceOracle,
            assetControllerAddr,
            params,
            strategy,
            highQuorum,
            blockingEnabled
        );

        proposal = address(new UUPSProxy(referenceImpl, initData));
    }
}
