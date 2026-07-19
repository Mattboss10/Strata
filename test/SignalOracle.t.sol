// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignalOracle} from "../src/SignalOracle.sol";

/// @dev A contract that can commit/reveal like any participant, but always reverts
///      on receiving ETH — simulating a broken or hostile contributor contract.
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

contract SignalOracleTest is Test {
    SignalOracle oracle;

    address settler = makeAddr("settler");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address sustainabilityFeeRecipient = makeAddr("sustainabilityFeeRecipient");

    uint256 constant COMMIT_DURATION = 5 minutes;
    uint256 constant REVEAL_DURATION = 5 minutes;
    uint256 constant MIN_STAKE = 0.01 ether;

    function setUp() public {
        oracle = new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, sustainabilityFeeRecipient, 0);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    function _commit(address who, uint256 value, bytes32 salt) internal {
        bytes32 commitment = keccak256(abi.encodePacked(value, salt));
        vm.prank(who);
        oracle.commit{value: MIN_STAKE}(commitment);
    }

    function testFullRoundHonestVsDishonest() public {
        _commit(alice, 1010, "alice-salt");
        _commit(bob, 5000, "bob-salt");
        _commit(carol, 1200, "carol-salt");

        vm.prank(alice);
        vm.expectRevert(SignalOracle.StillCommitting.selector);
        oracle.reveal(1010, "alice-salt");

        vm.warp(block.timestamp + COMMIT_DURATION + 1);

        vm.prank(alice);
        oracle.reveal(1010, "alice-salt");
        vm.prank(bob);
        oracle.reveal(5000, "bob-salt");

        vm.warp(block.timestamp + REVEAL_DURATION + 1);

        oracle.aggregateRound();
        assertEq(oracle.getCurrentSignal(), (1010 + 5000) / 2);

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;
        uint256 carolBalBefore = carol.balance;

        vm.prank(settler);
        oracle.settle(1000);

        uint256 slashPool = (MIN_STAKE / 2) + MIN_STAKE;
        assertEq(oracle.pendingWithdrawals(alice), MIN_STAKE + slashPool);
        assertEq(oracle.pendingWithdrawals(bob), MIN_STAKE / 2);
        assertEq(oracle.pendingWithdrawals(carol), 0);

        vm.prank(alice);
        oracle.withdraw();
        vm.prank(bob);
        oracle.withdraw();

        assertEq(alice.balance, aliceBalBefore + MIN_STAKE + slashPool);
        assertEq(oracle.reputation(alice), oracle.BASE_REPUTATION() + 10);

        assertEq(bob.balance, bobBalBefore + MIN_STAKE / 2);
        assertEq(oracle.reputation(bob), oracle.BASE_REPUTATION() - 10);

        assertEq(carol.balance, carolBalBefore);
        assertEq(oracle.reputation(carol), oracle.BASE_REPUTATION() - 20);
    }

    function testReputationCompoundsAcrossRounds() public {
        _commit(alice, 1000, "s1");
        _commit(bob, 2000, "s2");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "s1");
        vm.prank(bob);
        oracle.reveal(2000, "s2");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();
        vm.prank(settler);
        oracle.settle(1000);
        oracle.startNextRound();

        assertGt(oracle.reputation(alice), oracle.reputation(bob));

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        _commit(alice, 2000, "s3");
        _commit(bob, 9000, "s4");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(2000, "s3");
        vm.prank(bob);
        oracle.reveal(9000, "s4");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        uint256 signal = oracle.getCurrentSignal();
        uint256 simpleAverage = (2000 + 9000) / 2;
        assertLt(signal, simpleAverage, "weighted aggregate should skew toward the more reputable reporter");
    }

    function testCannotRevealWrongValue() public {
        _commit(alice, 1000, "salt");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(SignalOracle.HashMismatch.selector);
        oracle.reveal(9999, "salt");
    }

    function testCannotAggregateBeforeRevealWindowCloses() public {
        _commit(alice, 1000, "salt");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "salt");
        vm.expectRevert(SignalOracle.RevealStillOpen.selector);
        oracle.aggregateRound();
    }

    function testStakeTooLowReverts() public {
        vm.prank(alice);
        vm.expectRevert(SignalOracle.StakeTooLow.selector);
        oracle.commit{value: MIN_STAKE - 1}(keccak256(abi.encodePacked(uint256(1), bytes32("s"))));
    }

    function testBadReceiverCannotBlockSettlement() public {
        RevertingReceiver badActor = new RevertingReceiver();
        vm.deal(address(badActor), 1 ether);

        _commit(address(badActor), 1000, "bad-salt");
        _commit(alice, 1000, "alice-salt");

        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(address(badActor));
        oracle.reveal(1000, "bad-salt");
        vm.prank(alice);
        oracle.reveal(1000, "alice-salt");

        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        oracle.settle(1000);

        uint256 before = alice.balance;
        vm.prank(alice);
        oracle.withdraw();
        assertEq(alice.balance, before + MIN_STAKE);

        assertEq(oracle.pendingWithdrawals(address(badActor)), MIN_STAKE);
        vm.prank(address(badActor));
        vm.expectRevert();
        oracle.withdraw();
    }

    function testZeroParticipantRoundCarriesSignalForward() public {
        _commit(alice, 1234, "s1");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1234, "s1");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();
        vm.prank(settler);
        oracle.settle(1234);
        oracle.startNextRound();

        uint256 signalBefore = oracle.getCurrentSignal();
        assertEq(signalBefore, 1234);

        vm.warp(block.timestamp + COMMIT_DURATION + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        assertEq(oracle.getCurrentSignal(), signalBefore);

        vm.prank(settler);
        oracle.settle(0);
        oracle.startNextRound();
        assertEq(oracle.currentRoundId(), 3);
    }

    function testLastSignalUpdateTracksAggregation() public {
        assertEq(oracle.lastSignalUpdate(), 0);

        _commit(alice, 1000, "s1");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "s1");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);

        oracle.aggregateRound();
        assertEq(oracle.lastSignalUpdate(), block.timestamp);
    }

    function testFuzz_AggregateIsBoundedByRevealedValues(uint256 v1, uint256 v2) public {
        v1 = bound(v1, 1, type(uint128).max);
        v2 = bound(v2, 1, type(uint128).max);

        _commit(alice, v1, "s1");
        _commit(bob, v2, "s2");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(v1, "s1");
        vm.prank(bob);
        oracle.reveal(v2, "s2");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        uint256 agg = oracle.getCurrentSignal();
        uint256 lo = v1 < v2 ? v1 : v2;
        uint256 hi = v1 > v2 ? v1 : v2;
        assertGe(agg, lo);
        assertLe(agg, hi);
    }

    function testFuzz_AggregateIsBoundedByRevealedValues_UsingAssume(uint256 v1, uint256 v2, uint256 v3) public {
        vm.assume(!(v1 == v2 && v2 == v3));
        vm.assume(v1 < type(uint256).max / 1000);
        vm.assume(v2 < type(uint256).max / 1000);
        vm.assume(v3 < type(uint256).max / 1000);

        _commit(alice, v1, "s1");
        _commit(bob, v2, "s2");
        _commit(carol, v3, "s3");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(v1, "s1");
        vm.prank(bob);
        oracle.reveal(v2, "s2");
        vm.prank(carol);
        oracle.reveal(v3, "s3");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        uint256 agg = oracle.getCurrentSignal();
        uint256 lo = v1 < v2 ? (v1 < v3 ? v1 : v3) : (v2 < v3 ? v2 : v3);
        uint256 hi = v1 > v2 ? (v1 > v3 ? v1 : v3) : (v2 > v3 ? v2 : v3);
        assertGe(agg, lo);
        assertLe(agg, hi);
    }

    function testSettlerRotationRequiresAcceptance() public {
        address newSettler = makeAddr("newSettler");

        vm.prank(settler);
        oracle.proposeSettlerRotation(newSettler);

        assertEq(oracle.settler(), settler);

        vm.prank(alice);
        vm.expectRevert(SignalOracle.NotPendingSettler.selector);
        oracle.acceptSettlerRotation();

        vm.prank(newSettler);
        oracle.acceptSettlerRotation();
        assertEq(oracle.settler(), newSettler);

        _commit(alice, 1000, "s1");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "s1");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        vm.expectRevert(SignalOracle.NotSettler.selector);
        oracle.settle(1000);
    }

    function testOnlyCurrentSettlerCanProposeRotation() public {
        vm.prank(alice);
        vm.expectRevert(SignalOracle.NotSettler.selector);
        oracle.proposeSettlerRotation(alice);
    }

    function testSlashPoolCarriesForwardWhenNobodyAccurate() public {
        _commit(bob, 9000, "s1");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(bob);
        oracle.reveal(9000, "s1");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        oracle.settle(1000);

        uint256 expectedSlash = MIN_STAKE / 2;
        assertEq(oracle.carryoverPool(), expectedSlash);
        oracle.startNextRound();

        vm.deal(alice, 1 ether);
        _commit(alice, 1000, "s2");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "s2");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        oracle.settle(1000);

        assertEq(oracle.carryoverPool(), 0);
        assertEq(oracle.pendingWithdrawals(alice), MIN_STAKE + expectedSlash);
    }

    function testRealizedValueSanityBound() public {
        _commit(alice, 1000, "s1");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "s1");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(settler);
        vm.expectRevert(SignalOracle.RealizedValueOutOfBounds.selector);
        oracle.settle(10_001);

        vm.prank(settler);
        oracle.settle(10_000);
    }

    function testSustainabilityFeeTakenFromSlashPool() public {
        SignalOracle feeOracle = new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, sustainabilityFeeRecipient, 1000);

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        bytes32 aliceCommitment = keccak256(abi.encodePacked(uint256(1000), bytes32("s1")));
        bytes32 bobCommitment = keccak256(abi.encodePacked(uint256(9000), bytes32("s2")));

        vm.prank(alice);
        feeOracle.commit{value: MIN_STAKE}(aliceCommitment);
        vm.prank(bob);
        feeOracle.commit{value: MIN_STAKE}(bobCommitment);

        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        feeOracle.reveal(1000, "s1");
        vm.prank(bob);
        feeOracle.reveal(9000, "s2");

        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        feeOracle.aggregateRound();

        vm.prank(settler);
        feeOracle.settle(1000);

        uint256 bobSlash = MIN_STAKE / 2;
        uint256 expectedShare = (bobSlash * 1000) / 10_000;

        assertEq(feeOracle.pendingWithdrawals(sustainabilityFeeRecipient), expectedShare);

        uint256 remainingAfterShare = bobSlash - expectedShare;
        assertEq(feeOracle.pendingWithdrawals(alice), MIN_STAKE + remainingAfterShare);
    }

    function testSustainabilityFeeZeroWhenNoSlashOccurs() public {
        SignalOracle feeOracle = new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, sustainabilityFeeRecipient, 1000);

        vm.deal(alice, 1 ether);
        bytes32 commitment = keccak256(abi.encodePacked(uint256(1000), bytes32("s1")));
        vm.prank(alice);
        feeOracle.commit{value: MIN_STAKE}(commitment);

        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        feeOracle.reveal(1000, "s1");

        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        feeOracle.aggregateRound();

        vm.prank(settler);
        feeOracle.settle(1000);

        assertEq(feeOracle.pendingWithdrawals(sustainabilityFeeRecipient), 0);
    }

    function testSustainabilityFeeRecipientCannotBeZeroAddress() public {
        vm.expectRevert(SignalOracle.InvalidSustainabilityFeeRecipient.selector);
        new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, address(0), 500);
    }

    function testSustainabilityFeeCappedAtConstruction() public {
        uint256 tooHigh = 2001;
        vm.expectRevert(SignalOracle.SustainabilityFeeTooHigh.selector);
        new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, sustainabilityFeeRecipient, tooHigh);

        new SignalOracle(settler, COMMIT_DURATION, REVEAL_DURATION, MIN_STAKE, sustainabilityFeeRecipient, 2000);
    }

    function testSustainabilityFeeRecipientIsImmutable() public view {
        assertEq(oracle.sustainabilityFeeRecipient(), sustainabilityFeeRecipient);
        assertEq(oracle.sustainabilityFeeBps(), 0);
    }

    function testOnlySettlerCanSettle() public {
        _commit(alice, 1000, "salt");
        vm.warp(block.timestamp + COMMIT_DURATION + 1);
        vm.prank(alice);
        oracle.reveal(1000, "salt");
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.aggregateRound();

        vm.prank(alice);
        vm.expectRevert(SignalOracle.NotSettler.selector);
        oracle.settle(1000);
    }
}
