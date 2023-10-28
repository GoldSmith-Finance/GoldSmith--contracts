// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract GoldSmithState {
    enum MetalType {
        GOLD,
        SILVER
    }

    enum Action {
        MINT_METAL,
        BURN_METAL,
        TRANSFER_METAL,
        WITHDRAW,
        BORROW,
        REPAY
    }
}
