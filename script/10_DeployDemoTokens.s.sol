// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DeployDemoTokensScript is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 tokenA = new MockERC20("Strata Demo Token A", "SDA", 18);
        MockERC20 tokenB = new MockERC20("Strata Demo Token B", "SDB", 18);

        tokenA.mint(msg.sender, 1_000_000e18);
        tokenB.mint(msg.sender, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("Token A deployed at:", address(tokenA));
        console2.log("Token B deployed at:", address(tokenB));
        console2.log("Copy both addresses into script/base/BaseScript.sol's token0/token1 constants.");
    }
}
