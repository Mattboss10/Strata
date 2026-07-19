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

    mapping(address => uint256) public reputation;
    uint256 public constant BASE_REPUTATION = 100;

    uint256 public latestSignal;
    uint256 public lastSignalUpdate;
    mapping(address => uint256) public pendingWithdrawals;

    address public settler;
    address public pendingSettler;
    uint256 public carryoverPool;

    /// @notice A small share of slashed/forfeited stakes routed to this address, funding
    ///         ongoing maintenance of the oracle and hook. Set once at deployment, never
    ///         changeable by anyone afterward -- not even by this address itself. No
    ///         setter function exists for either of these two values.
    address public immutable sustainabilityFeeRecipient;
    uint256 public immutable sustainabilityFeeBps;

    /// @dev Hard ceiling on the sustainability fee, enforced at construction so no
    ///      deployment can ever set a share large enough to gut the incentive for
    ///      accurate reporting.
    uint256 public constant MAX_SUSTAINABILITY_FEE_BPS = 2000; // 20%

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
    error InvalidSustainabilityFeeRecipient();
    error SustainabilityFeeTooHigh();

    constructor(
        address _settler,
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _minStake,
        address _sustainabilityFeeRecipient,
        uint256 _sustainabilityFeeBps
    ) {
        if (_sustainabilityFeeRecipient == address(0)) revert InvalidSustainabilityFeeRecipient();
        if (_sustainabilityFeeBps > MAX_SUSTAINABILITY_FEE_BPS) revert SustainabilityFeeTooHigh();

        settler = _settler;
        commitDuration = _commitDuration;
        revealDuration = _revealDuration;
        minStake = _minStake;
        sustainabilityFeeRecipient = _sustainabilityFeeRecipient;
        sustainabilityFeeBps = _sustainabilityFeeBps;
        currentRoundId = 1;
        rounds[currentRoundId].startTime = block.timestamp;
        emit RoundStarted(currentRoundId, block.timestamp);
    }

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

    function proposeSettlerRotation(address newSettler) external {
        if (msg.sender != settler) revert NotSettler();
        pendingSettler = newSettler;
        emit SettlerRotationProposed(newSettler);
    }

    function acceptSettlerRotation() external {
        if (msg.sender != pendingSettler) revert NotPendingSettler();
        address old = settler;
        settler = pendingSettler;
        pendingSettler = address(0);
        emit SettlerRotated(old, settler);
    }

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

        uint256 newSlashPool = 0;
        uint256 accurateStakeTotal;
        bool[] memory isAccurate = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            address p = r.participants[i];
            uint256 stake = r.stakes[p];

            if (!r.revealed[p]) {
                reputation[p] = reputation[p] > 20 ? reputation[p] - 20 : 1;
                newSlashPool += stake;
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
                newSlashPool += slashAmount;
                pendingWithdrawals[p] += stake - slashAmount;
            }
        }

        uint256 sustainabilityShare = (newSlashPool * sustainabilityFeeBps) / 10_000;
        if (sustainabilityShare > 0) {
            pendingWithdrawals[sustainabilityFeeRecipient] += sustainabilityShare;
        }
        uint256 distributable = carryoverPool + (newSlashPool - sustainabilityShare);

        if (accurateStakeTotal > 0) {
            for (uint256 i = 0; i < len; i++) {
                if (!isAccurate[i]) continue;
                address p = r.participants[i];
                uint256 stake = r.stakes[p];
                uint256 bonus = (distributable * stake) / accurateStakeTotal;
                pendingWithdrawals[p] += stake + bonus;
            }
            carryoverPool = 0;
        } else {
            carryoverPool = distributable;
        }

        emit Settled(currentRoundId, realizedValue);
    }

    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function startNextRound() external {
        if (!rounds[currentRoundId].settled) revert SettleCurrentRoundFirst();
        currentRoundId++;
        rounds[currentRoundId].startTime = block.timestamp;
        emit RoundStarted(currentRoundId, block.timestamp);
    }

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
