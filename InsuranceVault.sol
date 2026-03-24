// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract InsuranceVault is AccessControl, Pausable, ReentrancyGuard {

    // ========================= ROLES =========================
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER");

    // ========================= EVENTS =========================
    event LossCovered(address indexed to, uint256 amount);
    event FundsReceived(address indexed from, uint256 amount);

    // ========================= CONSTRUCTOR =========================
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
    }

    // ========================= COVER LOSS =========================
    function coverLoss(address to, uint256 amount)
        external
        onlyRole(SLASHER_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");

        uint256 balance = address(this).balance;

        // 🔒 Safety check — нельзя вывести больше, чем есть
        require(balance >= amount, "Insufficient insurance funds");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Transfer failed");

        emit LossCovered(to, amount);
    }

    // ========================= EMERGENCY CONTROL =========================
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========================= RECEIVE =========================
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }
}