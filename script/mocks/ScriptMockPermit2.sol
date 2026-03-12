// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPermit2} from "../../src/lib/IPermit2.sol";

contract ScriptMockPermit2 is IPermit2 {
    function approve(address, address, uint160, uint48) external pure {}

    function transferFrom(address from, address to, uint160 amount, address token) external {
        ERC20(token).transferFrom(from, to, amount);
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    ) external {
        ERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}
