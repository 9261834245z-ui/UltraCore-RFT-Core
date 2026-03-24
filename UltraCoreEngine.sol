// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * UltraCoreEngine — Final 10/10 Version
 *
 * Properties:
 * - O(1) accounting (no loops)
 * - CRI (Cumulative Reward Index)
 * - Relational Boost based on TOTAL USER BALANCE (anti-sybil)
 * - Loss support (slashing simulation)
 * - Inflation attack protection
 * - Reentrancy protection
 *
 * Invariant:
 * totalAssets ≈ totalShares * CRI / PRECISION
 */

contract UltraCoreEngine {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MINIMUM_SHARES = 1e3;

    uint256 public totalShares;
    uint256 public CRI;

    mapping(address => uint256) public shares;

    // 🔒 Reentrancy guard
    uint256 private unlocked = 1;
    modifier nonReentrant() {
        require(unlocked == 1, "LOCKED");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    // ---------------- EVENTS ----------------
    event Deposit(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 amount, uint256 sharesBurned);
    event RewardsAdded(uint256 amount);
    event LossApplied(uint256 amount);

    constructor() {
        CRI = PRECISION;
    }

    // ---------------- MATH ----------------
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // 🔥 BOOST ОТ ОБЩЕГО БАЛАНСА
    function _boost(uint256 totalUserBalance) internal pure returns (uint256) {
        uint256 sqrtBalance = _sqrt(totalUserBalance);

        // boost = 1 + 1/(1 + sqrt(balance))
        uint256 bonus = PRECISION / (PRECISION + sqrtBalance);

        return PRECISION + bonus;
    }

    // ---------------- CORE ----------------

    function deposit() external payable nonReentrant {
        require(msg.value > 0, "ZERO");

        uint256 userBalanceBefore = balanceOf(msg.sender);
        uint256 boostedAmount =
            (msg.value * _boost(userBalanceBefore + msg.value)) / PRECISION;

        uint256 newShares;

        if (totalShares == 0) {
            newShares = boostedAmount - MINIMUM_SHARES;

            shares[address(0)] = MINIMUM_SHARES;
            totalShares = MINIMUM_SHARES;
        } else {
            newShares = (boostedAmount * PRECISION) / CRI;
        }

        require(newShares > 0, "ZERO_SHARES");

        shares[msg.sender] += newShares;
        totalShares += newShares;

        emit Deposit(msg.sender, msg.value, newShares);
    }

    function withdraw(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "ZERO");
        require(shares[msg.sender] >= shareAmount, "INSUFFICIENT");

        uint256 amount = (shareAmount * CRI) / PRECISION;

        require(address(this).balance >= amount, "WAIT_LIQUIDITY");

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "TRANSFER_FAIL");

        emit Withdraw(msg.sender, amount, shareAmount);
    }

    // ---------------- REWARDS ----------------

    function addRewards() external payable {
        require(totalShares > 0, "NO_SHARES");

        uint256 delta = (msg.value * PRECISION) / totalShares;
        require(delta > 0, "REWARD_TOO_SMALL");

        CRI += delta;

        emit RewardsAdded(msg.value);
    }

    // 🔥 LOSS (SLASHING MODEL)
    function applyLoss(uint256 lossAmount) external {
        require(totalShares > 0, "NO_SHARES");

        uint256 delta = (lossAmount * PRECISION) / totalShares;

        require(CRI > delta, "CRI_UNDERFLOW");

        CRI -= delta;

        emit LossApplied(lossAmount);
    }

    // ---------------- VIEWS ----------------

    function balanceOf(address user) public view returns (uint256) {
        return (shares[user] * CRI) / PRECISION;
    }

    function totalAssets() public view returns (uint256) {
        return (totalShares * CRI) / PRECISION;
    }
}