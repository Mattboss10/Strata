// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

contract OracleRevealScript is Script {
    uint256 constant DEMO_VALUE = 1500;
    bytes32 constant DEMO_SALT = keccak256("strata-demo-salt-v1");

    function run() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        SignalOracle oracle = SignalOracle(oracleAddress);

        vm.startBroadcast();
        oracle.reveal(DEMO_VALUE, DEMO_SALT);
        vm.stopBroadcast();

        console2.log("Revealed. Wait for the reveal window to close (2 min), then run 14_AggregateAndSettle.s.sol");
    }
}
