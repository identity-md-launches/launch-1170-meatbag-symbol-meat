// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The heartbeat treasury
/// @notice Holds the 20% of every hook fee that funds the swarm's 12-hour heartbeat. `fundNextRun` is
/// public: anyone may call it, at most once per 12 hours, and it sends at most 0.01 ETH per call to the
/// swarm's wallet, which funds the IMD job schedule (cadence PT12H) that improves the site or adds
/// opt-in features. This contract holds nothing else and can touch nothing else: not the pot, not the
/// fee rates, not the supply and not any holder's funds.
contract HeartbeatTreasury {
    event HeartbeatFunded(address indexed to, uint256 amount, uint256 at);

    error TooSoon(uint256 nextRunAt);
    error NothingToSend();
    error SendFailed();

    /// @notice The swarm's wallet: where each heartbeat's funding goes.
    address public constant SWARM = 0xd01122bBfFd00fc96252c8b29867a5359a3bca13;
    /// @notice The most one call may send.
    uint256 public constant CAP_PER_RUN = 0.01 ether;
    /// @notice The least time between two calls.
    uint256 public constant INTERVAL = 12 hours;

    /// @notice When `fundNextRun` last paid out. Zero until the first run.
    uint256 public lastRunAt;

    receive() external payable {}

    /// @notice The earliest moment the next run may be funded.
    function nextRunAt() public view returns (uint256) {
        return lastRunAt == 0 ? 0 : lastRunAt + INTERVAL;
    }

    /// @notice Sends min(balance, 0.01 ETH) to the swarm's wallet. Anyone may call it once per 12 hours.
    function fundNextRun() external returns (uint256 amount) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < nextRunAt()) revert TooSoon(nextRunAt());
        amount = address(this).balance;
        if (amount > CAP_PER_RUN) amount = CAP_PER_RUN;
        if (amount == 0) revert NothingToSend();
        lastRunAt = block.timestamp;
        (bool ok,) = SWARM.call{value: amount}("");
        if (!ok) revert SendFailed();
        emit HeartbeatFunded(SWARM, amount, block.timestamp);
    }
}
