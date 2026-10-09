// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MEATBAG ($MEAT), the launch's standard token
/// @notice A fixed-supply ERC-20: 1,000,000,000 tokens at 18 decimals, minted once to the deployer (the
/// launch factory, which splits it between the swarm's distributor and the pool). No owner, no mint,
/// no pause, no blocklist, no fee on transfer and no upgrade path. Every fee lives in `MeatbagHook`.
contract MeatbagToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("MEATBAG", "MEAT") {
        _mint(msg.sender, SUPPLY);
    }
}
