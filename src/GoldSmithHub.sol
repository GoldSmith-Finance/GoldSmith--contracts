// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./GoldSmithState.sol";
import "message-bridge-contracts/WmbApp.sol";

contract GoldSmithHub is GoldSmithState, WmbApp {
    /* ================ CONTRACT MAIN STATE VARS ================ */

    mapping(MetalType => uint256) public totalSupply;

    /* ================ CONTRACT MAIN FUNCTIONS ================ */

    constructor(address admin, address _wmbGateway) {
        initialize(admin, _wmbGateway);
    }

    function mintMetal(bytes memory payload) private {
        (, , MetalType metalType, uint256 tokensMinted) = abi.decode(
            payload,
            (Action, address, MetalType, uint256)
        );

        totalSupply[metalType] += tokensMinted;
    }

    function burnMetal(bytes memory payload) private {
        (, , MetalType metalType, uint256 tokensBurned) = abi.decode(
            payload,
            (Action, address, MetalType, uint256)
        );

        totalSupply[metalType] -= tokensBurned;
    }

    function _wmbReceive(
        bytes calldata data,
        bytes32 messageId,
        uint256 fromChainId,
        address fromSC
    ) internal override {
        // do something you want...

        Action actionType = abi.decode(data, (Action));

        if (actionType == Action.MINT_METAL) {
            mintMetal(payload);
        } else if (actionType == Action.BURN_METAL) {
            burnMetal(payload);
        }
    }
}
