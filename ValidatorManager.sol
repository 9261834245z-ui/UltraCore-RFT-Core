// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IDepositContract {
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;
}

contract ValidatorManager is AccessControl, Pausable {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    uint256 public constant VALIDATOR_SIZE = 32 ether;

    IDepositContract public immutable beaconDeposit;

    uint256 public pending;

    // 🔐 Жёстко зафиксированные withdrawal credentials
    bytes public withdrawalCredentials;

    event ValidatorLaunched(bytes pubkey);
    event WithdrawalCredentialsSet(bytes credentials);

    constructor(bytes memory _withdrawalCredentials) {
        require(_withdrawalCredentials.length == 32, "Invalid credentials");

        beaconDeposit = IDepositContract(
            0x00000000219ab540356cBB839Cbe05303d7705Fa
        );

        withdrawalCredentials = _withdrawalCredentials;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // 🔒 Только Vault / оператор может отправлять ETH
    function deposit() external payable onlyRole(OPERATOR_ROLE) {
        require(msg.value > 0, "Zero deposit");

        unchecked {
            pending += msg.value;
        }
    }

    // 🔐 Возможность обновить withdrawal credentials (только админ)
    function setWithdrawalCredentials(bytes calldata _credentials)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_credentials.length == 32, "Invalid credentials");

        withdrawalCredentials = _credentials;

        emit WithdrawalCredentialsSet(_credentials);
    }

    // 🚨 Circuit Breaker
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // 🚀 Запуск валидатора (Production-ready)
    function launchValidator(
        bytes calldata pubkey,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {

        // ✅ Строгая валидация данных
        require(pubkey.length == 48, "Invalid pubkey");
        require(signature.length == 96, "Invalid signature");

        require(pending >= VALIDATOR_SIZE, "Insufficient pending");

        // 🔥 Оптимизированное обновление
        unchecked {
            pending -= VALIDATOR_SIZE;
        }

        beaconDeposit.deposit{value: VALIDATOR_SIZE}(
            pubkey,
            withdrawalCredentials,
            signature,
            deposit_data_root
        );

        emit ValidatorLaunched(pubkey);
    }
}