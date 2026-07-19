// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Round-based commit-reveal risk-signal aggregator.
/// @dev Contributors stake ETH, commit a hidden value, reveal it once the window closes,
///      and get scored against a realized outcome posted by `settler` (a placeholder for
///      a real price/volatility oracle — wiring that in is a later-week task).
///      This contract has no knowledge of the hook or PoolManager. The hook only ever
///      calls `getCurrentSignal()`.
contract SignalOracle {
    uint256 public immutable commitDuration;
    uint256 public immutable revealDuration;
    uint256 public immutable minStake;

    struct Round {
        uint256 startTime;
        address[] participants;
        mapping(address => bytes32) commitments;
        mapping(address => uint256) stakes;
        mapping(address => uint256) revealedValue;
        mapping(address => bool) revealed;
        uint256 aggregateValue;
        bool aggregated;
        uint256 realizedValue;
        bool settled;
    }

    mapping(uint256 => Round) internal rounds;
    uint256 public currentRoundId;

    /// @notice Reputation acts as aggregation weight. Starts at BASE_REPUTATION on first commit.
    mapping(address => uint256) public reputation;
    uint256 public constant BASE_REPUTATION = 100;

    /// @notice The last finalized aggregate. This is the one value the hook reads.
    uint256 public latestSignal;

    /// @notice Timestamp of the last successful aggregation, so a consumer (like the
    ///         hook) can detect a stale signal and fall back to a safe default.
    uint256 public lastSignalUpdate;

    /// @notice Pull-payment balances, credited by settle(), withdrawn via withdraw().
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Stand-in for an oracle/keeper role that posts the realized outcome after the fact.
    address public settler;

    /// @notice A proposed new settler, awaiting acceptance. Two-step rotation avoids
    ///         accidentally handing the role to an address that can't act on it.
    address public pendingSettler;

    /// @notice Slashed stakes that couldn't be distributed this round (because nobody
    ///         was accurate) roll forward here instead of sitting stuck permanently.
    uint256 public carryoverPool;

    event Committed(uint256 indexed roundId, address indexed contributor, uint256 stake);
    event Revealed(uint256 indexed roundId, address indexed contributor, uint256 value);
    event Aggregated(uint256 indexed roundId, uint256 aggregateValue, uint256 participantCount);
    event Settled(uint256 indexed roundId, uint256 realizedValue);
    event RoundStarted(uint256 indexed roundId, uint256 startTime);
    event SettlerRotationProposed(address indexed proposed);
    event SettlerRotated(address indexed oldSettler, address indexed newSettler);

    error CommitWindowClosed();
    error StakeTooLow();
    error AlreadyCommitted();
    error StillCommitting();
    error RevealWindowClosed();
    error AlreadyRevealed();
    error HashMismatch();
    error RevealStillOpen();
    error AlreadyAggregated();
    error NotAggregatedYet();
    error AlreadySettled();
    error NotSettler();
    error NotPendingSettler();
    error SettleCurrentRoundFirst();
    error NothingToWithdraw();
    error RealizedValueOutOfBounds();

    constructor(address _settler, uint256 _commitDuration, uint256 _revealDuration, uint256 _minStake) {
        settler = _settler;
        commitDuration = _commitDuration;
        revealDuration = _revealDuration;
        minStake = _minStake;
        currentRoundId = 1;
        rounds[currentRoundId].startTime = block.timestamp;
        emit RoundStarted(currentRoundId, block.timestamp);
    }

    /// @notice Submit a hidden prediction. commitment = keccak256(abi.encodePacked(value, salt)).
    function commit(bytes32 commitment) external payable {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp >= r.startTime + commitDuration) revert CommitWindowClosed();
        if (msg.value < minStake) revert StakeTooLow();
        if (r.commitments[msg.sender] != bytes32(0)) revert AlreadyCommitted();

        r.commitments[msg.sender] = commitment;
        r.stakes[msg.sender] = msg.value;
        r.participants.push(msg.sender);
        if (reputation[msg.sender] == 0) reputation[msg.sender] = BASE_REPUTATION;

        emit Committed(currentRoundId, msg.sender, msg.value);
    }

    /// @notice Reveal the value + salt behind your earlier commitment.
    function reveal(uint256 value, bytes32 salt) external {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp < r.startTime + commitDuration) revert StillCommitting();
        if (block.timestamp >= r.startTime + commitDuration + revealDuration) revert RevealWindowClosed();
        if (r.revealed[msg.sender]) revert AlreadyRevealed();
        if (keccak256(abi.encodePacked(value, salt)) != r.commitments[msg.sender]) revert HashMismatch();

        r.revealedValue[msg.sender] = value;
        r.revealed[msg.sender] = true;

        emit Revealed(currentRoundId, msg.sender, value);
    }

    /// @notice Current settler proposes a replacement. Doesn't take effect until accepted.
    function proposeSettlerRotation(address newSettler) external {
        if (msg.sender != settler) revert NotSettler();
        pendingSettler = newSettler;
        emit SettlerRotationProposed(newSettler);
    }

    /// @notice The proposed address must accept before the rotation takes effect — this
    ///         is what prevents accidentally handing the role to an address that can't
    ///         act on it (a typo, a contract with no way to call settle(), etc.).
    function acceptSettlerRotation() external {
        if (msg.sender != pendingSettler) revert NotPendingSettler();
        address old = settler;
        settler = pendingSettler;
        pendingSettler = address(0);
        emit SettlerRotated(old, settler);
    }

    /// @notice Once the reveal window closes, anyone can trigger aggregation.
    function aggregateRound() external {
        Round storage r = rounds[currentRoundId];
        if (block.timestamp < r.startTime + commitDuration + revealDuration) revert RevealStillOpen();
        if (r.aggregated) revert AlreadyAggregated();

        uint256 weightedSum;
        uint256 totalWeight;
        uint256 len = r.participants.length;
        for (uint256 i = 0; i < len; i++) {
            address p = r.participants[i];
            if (r.revealed[p]) {
                uint256 w = reputation[p];
                weightedSum += r.revealedValue[p] * w;
                totalWeight += w;
            }
        }

        if (totalWeight == 0) {
            r.aggregateValue = latestSignal;
        } else {
            r.aggregateValue = weightedSum / totalWeight;
            latestSignal = r.aggregateValue;
        }

        r.aggregated = true;
        lastSignalUpdate = block.timestamp;

        emit Aggregated(currentRoundId, r.aggregateValue, len);
    }

    /// @notice Settler posts what actually happened. Rewards accurate reporters, slashes inaccurate
    ///         ones, and never-revealed committers forfeit their stake entirely. Everything that
    ///         gets slashed or forfeited this round is redistributed pro-rata to the accurate
    ///         reporters in the SAME round — nothing sits parked in the contract with no way out.
    ///         If nobody was accurate this round, the pool rolls forward to the next round that
    ///         has at least one accurate reporter, rather than getting stuck.
    function settle(uint256 realizedValue) external {
        if (msg.sender != settler) revert NotSettler();
        Round storage r = rounds[currentRoundId];
        if (!r.aggregated) revert NotAggregatedYet();
        if (r.settled) revert AlreadySettled();

        if (r.aggregateValue > 0 && realizedValue > r.aggregateValue * 10) {
            revert RealizedValueOutOfBounds();
        }

        r.realizedValue = realizedValue;
        r.settled = true;

        uint256 tolerance = realizedValue / 10;
        uint256 len = r.participants.length;

        uint256 slashPool = carryoverPool;
        uint256 accurateStakeTotal;
        bool[] memory isAccurate = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            address p = r.participants[i];
            uint256 stake = r.stakes[p];

            if (!r.revealed[p]) {
                reputation[p] = reputation[p] > 20 ? reputation[p] - 20 : 1;
                slashPool += stake;
                continue;
            }

            uint256 err = _absDiff(r.revealedValue[p], realizedValue);
            if (err <= tolerance) {
                reputation[p] += 10;
                isAccurate[i] = true;
                accurateStakeTotal += stake;
            } else {
                reputation[p] = reputation[p] > 10 ? reputation[p] - 10 : 1;
                uint256 slashAmount = stake / 2;
                slashPool += slashAmount;
                pendingWithdrawals[p] += stake - slashAmount;
            }
        }

        if (accurateStakeTotal > 0) {
            for (uint256 i = 0; i < len; i++) {
                if (!isAccurate[i]) continue;
                address p = r.participants[i];
                uint256 stake = r.stakes[p];
                uint256 bonus = (slashPool * stake) / accurateStakeTotal;
                pendingWithdrawals[p] += stake + bonus;
            }
            carryoverPool = 0;
        } else {
            carryoverPool = slashPool;
        }

        emit Settled(currentRoundId, realizedValue);
    }

    /// @notice Pull-payment withdrawal. Settling a round only credits a balance —
    ///         it never sends ETH directly.
    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    /// @notice Starts the next round. Requires the current one to be fully settled.
    function startNextRound() external {
        if (!rounds[currentRoundId].settled) revert SettleCurrentRoundFirst();
        currentRoundId++;
        rounds[currentRoundId].startTime = block.timestamp;
        emit RoundStarted(currentRoundId, block.timestamp);
    }

    /// @notice The one function the hook actually calls.
    function getCurrentSignal() external view returns (uint256) {
        return latestSignal;
    }

    function getRoundInfo(uint256 roundId)
        external
        view
        returns (uint256 startTime, uint256 participantCount, bool aggregated, bool settled, uint256 aggregateValue)
    {
        Round storage r = rounds[roundId];
        return (r.startTime, r.participants.length, r.aggregated, r.settled, r.aggregateValue);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
