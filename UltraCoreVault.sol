// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IValidatorManager {
    function deposit() external payable;
}

contract UltraCoreVault is ReentrancyGuard, AccessControl {

    // ========================= ROLES =========================
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER");

    // ========================= CONSTANTS =========================
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BOOST_PRECISION = 1e18;

    // ========================= STATE =========================
    uint256 public accRewardPerShare;
    uint256 public totalShares;

    IValidatorManager public immutable validator;
    address public immutable insuranceVault;

    struct User {
        uint256 balance;
        uint256 shares;
        uint256 rewardDebt;
    }

    mapping(address => User) public users;

    // ========================= EVENTS =========================
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 reward);
    event RewardsAdded(uint256 total, uint256 insuranceCut);

    // ========================= CONSTRUCTOR =========================
    constructor(address _validator, address _insuranceVault) {
        require(_validator != address(0), "Validator=0");
        require(_insuranceVault != address(0), "Insurance=0");

        validator = IValidatorManager(_validator);
        insuranceVault = _insuranceVault;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    // =====================================================
    // 🔥 RELATIONAL BOOST (continuous, anti-whale)
    // =====================================================
    function _boost(uint256 balance) internal pure returns (uint256) {
        if (balance == 0) return BOOST_PRECISION;

        // boost = 1 + 1 / (1 + sqrt(balance))
        uint256 x = (balance * BOOST_PRECISION) / 1 ether;

        uint256 sqrtX = _sqrt(x);

        uint256 denominator = BOOST_PRECISION + sqrtX;

        uint256 extra = (BOOST_PRECISION * BOOST_PRECISION) / denominator;

        if (extra > BOOST_PRECISION) extra = BOOST_PRECISION;

        return BOOST_PRECISION + extra; // диапазон ~1x–2x
    }

    // =====================================================
    // 📥 DEPOSIT
    // =====================================================
    function deposit() external payable nonReentrant {
        require(msg.value >= 0.01 ether, "Min 0.01 ETH");

        User storage user = users[msg.sender];

        _harvest(msg.sender);

        user.balance += msg.value;

        uint256 newShares = _calculateShares(user.balance);

        totalShares = totalShares - user.shares + newShares;

        user.shares = newShares;
        user.rewardDebt = (user.shares * accRewardPerShare) / PRECISION;

        validator.deposit{value: msg.value}();

        emit Deposit(msg.sender, msg.value);
    }

    // =====================================================
    // 📤 WITHDRAW
    // =====================================================
    function withdraw(uint256 amount) external nonReentrant {
        User storage user = users[msg.sender];

        require(user.balance >= amount, "Insufficient balance");

        // 🔴 ВАЖНО: ликвидность может быть в валидаторах
        require(address(this).balance >= amount, "Wait for validator exit");

        _harvest(msg.sender);

        user.balance -= amount;

        uint256 newShares = _calculateShares(user.balance);

        totalShares = totalShares - user.shares + newShares;

        user.shares = newShares;
        user.rewardDebt = (user.shares * accRewardPerShare) / PRECISION;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit Withdraw(msg.sender, amount);
    }

    // =====================================================
    // 💰 ADD REWARDS (AUTO INSURANCE CUT)
    // =====================================================
    function addRewards() external payable onlyRole(KEEPER_ROLE) {
        require(totalShares > 0, "No shares");
        require(msg.value > 0, "No rewards");

        uint256 insuranceCut = (msg.value * 5) / 100;
        uint256 netRewards = msg.value - insuranceCut;

        // 🔐 отправка в страховку
        (bool ok, ) = insuranceVault.call{value: insuranceCut}("");
        require(ok, "Insurance transfer failed");

        accRewardPerShare += (netRewards * PRECISION) / totalShares;

        emit RewardsAdded(netRewards, insuranceCut);
    }

    // =====================================================
    // 🌾 HARVEST
    // =====================================================
    function harvest() external nonReentrant {
        _harvest(msg.sender);
    }

    function _harvest(address userAddr) internal {
        User storage user = users[userAddr];

        if (user.shares == 0) return;

        uint256 accumulated = (user.shares * accRewardPerShare) / PRECISION;

        uint256 pending = accumulated > user.rewardDebt
            ? accumulated - user.rewardDebt
            : 0;

        if (pending > 0) {
            user.rewardDebt = accumulated;

            (bool ok, ) = userAddr.call{value: pending}("");
            require(ok, "Reward transfer failed");

            emit Harvest(userAddr, pending);
        }
    }

    // =====================================================
    // 🧮 SHARE CALCULATION
    // =====================================================
    function _calculateShares(uint256 balance) internal pure returns (uint256) {
        if (balance == 0) return 0;

        uint256 boost = _boost(balance);

        return (balance * boost) / BOOST_PRECISION;
    }

    // =====================================================
    // 🔢 SQRT (Babylonian)
    // =====================================================
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    receive() external payable {}
}