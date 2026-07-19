// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

/// @notice Drives randomized sequences of commit/reveal/aggregate/settle/withdraw calls
///         against a SignalOracle. Every action is wrapped in try/catch so an invalid-state
///         call is just a no-op for the fuzzer instead of derailing the run.
contract SignalOracleHandler is Test {
    SignalOracle public oracle;
    address public settler;

    address[] public actors;
    mapping(address => uint256) public lastCommittedValue;
    mapping(address => bytes32) public lastSalt;

    uint256 public constant STAKE = 0.01 ether;

    constructor(SignalOracle _oracle, address _settler, address[] memory _actors) {
        oracle = _oracle;
        settler = _settler;
        actors = _actors;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function commit(uint256 actorSeed, uint256 value) external {
        address actor = _actor(actorSeed);
        value = bound(value, 1, 1_000_000);
        bytes32 salt = keccak256(abi.encode(actor, value, block.timestamp));
        bytes32 commitment = keccak256(abi.encodePacked(value, salt));

        vm.deal(actor, STAKE);
        vm.prank(actor);
        try oracle.commit{value: STAKE}(commitment) {
            lastCommittedValue[actor] = value;
            lastSalt[actor] = salt;
        } catch {}
    }

    function reveal(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try oracle.reveal(lastCommittedValue[actor], lastSalt[actor]) {} catch {}
    }

    function warpPastCommitWindow() external {
        vm.warp(block.timestamp + 5 minutes + 1);
    }

    function warpPastRevealWindow() external {
        vm.warp(block.timestamp + 5 minutes + 1);
    }

    function aggregate() external {
        try oracle.aggregateRound() {} catch {}
    }

    function settle(uint256 realizedValueSeed) external {
        uint256 realizedValue = bound(realizedValueSeed, 0, 10_000_000);
        vm.prank(settler);
        try oracle.settle(realizedValue) {} catch {}
    }

    function startNextRound() external {
        try oracle.startNextRound() {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try oracle.withdraw() {} catch {}
    }
}
