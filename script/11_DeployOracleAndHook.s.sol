// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {SignalOracle} from "../src/SignalOracle.sol";
import {LvrFeeHook} from "../src/LvrFeeHook.sol";

contract DeployOracleAndHookScript is BaseScript {
    function run() public {
        vm.startBroadcast();

        SignalOracle oracle = new SignalOracle({
            _settler: deployerAddress,
            _commitDuration: 2 minutes,
            _revealDuration: 2 minutes,
            _minStake: 0.001 ether
        });

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, oracle);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(LvrFeeHook).creationCode, constructorArgs);

        LvrFeeHook hook = new LvrFeeHook{salt: salt}(poolManager, oracle);
        require(address(hook) == hookAddress, "DeployOracleAndHookScript: Hook Address Mismatch");

        vm.stopBroadcast();

        console2.log("SignalOracle deployed at:", address(oracle));
        console2.log("LvrFeeHook deployed at:  ", address(hook));
        console2.log("Copy the hook address into script/base/BaseScript.sol's hookContract constant.");
        console2.log("Settler (for oracle commit/reveal/settle) is:", deployerAddress);
    }
}
