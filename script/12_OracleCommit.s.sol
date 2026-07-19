// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

contract OracleCommitScript is Script {
    uint256 constant DEMO_VALUE = 1500;
    bytes32 constant DEMO_SALT = keccak256("strata-demo-salt-v1");

    function run() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        SignalOracle oracle = SignalOracle(oracleAddress);

        bytes32 commitment = keccak256(abi.encodePacked(DEMO_VALUE, DEMO_SALT));

        vm.startBroadcast();
        oracle.commit{value: 0.001 ether}(commitment);
        vm.stopBroadcast();

        console2.log("Committed. Wait for the commit window to close (2 min), then run 13_OracleReveal.s.sol");
    }
}
