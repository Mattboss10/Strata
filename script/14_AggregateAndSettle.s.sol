// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {SignalOracle} from "../src/SignalOracle.sol";
import {LvrFeeHook} from "../src/LvrFeeHook.sol";

contract AggregateAndSettleScript is Script {
    uint256 constant DEMO_REALIZED_VALUE = 9000;

    function run() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        SignalOracle oracle = SignalOracle(oracleAddress);
        LvrFeeHook hook = LvrFeeHook(hookAddress);

        console2.log("Fee BEFORE this round settles:", hook.previewFee());

        vm.startBroadcast();
        oracle.aggregateRound();
        oracle.settle(DEMO_REALIZED_VALUE);
        vm.stopBroadcast();

        console2.log("Fee AFTER settling:          ", hook.previewFee());
        console2.log("Now run 15_CreatePoolAndAddLiquidity.s.sol, then 16_Swap.s.sol to see it charged for real.");
    }
}
