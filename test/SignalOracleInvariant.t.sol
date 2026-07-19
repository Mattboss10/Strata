// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignalOracle} from "../src/SignalOracle.sol";
import {SignalOracleHandler} from "./SignalOracleHandler.sol";

/// @notice The core fund-safety property: no sequence of commits, reveals, aggregations,
///         settlements, or withdrawals should ever be able to leave the oracle owing more
///         ETH than it actually holds.
contract SignalOracleInvariantTest is Test {
    SignalOracle oracle;
    SignalOracleHandler handler;
    address settler;

    function setUp() public {
        settler = makeAddr("invariantSettler");

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("invActor1");
        actors[1] = makeAddr("invActor2");
        actors[2] = makeAddr("invActor3");
        actors[3] = makeAddr("invActor4");

        oracle = new SignalOracle(settler, 5 minutes, 5 minutes, 0.01 ether);
        handler = new SignalOracleHandler(oracle, settler, actors);

        targetContract(address(handler));
    }

    function invariant_solvency() public view {
        uint256 totalPending;
        uint256 len = handler.actorsLength();
        for (uint256 i = 0; i < len; i++) {
            totalPending += oracle.pendingWithdrawals(handler.actors(i));
        }
        assertGe(address(oracle).balance, totalPending);
    }
}
