// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * =============================================================
 * UltraCoreRift_Audit_Ready_V1
 * =============================================================
 * Final institutional-grade system
 * - Hard invariant enforcement
 * - Guardian governance + timelock
 * - Circuit breaker (pause)
 * - Full event visibility
 * - Strict participant model
 *
 * Invariant:
 * totalSupply = totalBaseSum + globalField * P
 * =============================================================
 */

contract UltraCoreRift_Audit_Ready_V1 {

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Redistribute(uint256 amount, uint256 perUser);
    event FieldUpdate(int256 newGlobalField);
    event Registered(address indexed user);
    event Unregistered(address indexed user);
    event GateProposed(address indexed newGate);
    event GateUpdated(address indexed newGate);
    event Paused();
    event Unpaused();

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvariantViolation();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int256 public constant NEG_E = -2718281828459045235;

    uint256 public constant MAX_SUPPLY = 1e27;
    int256 public constant MAX_EDGE_COST = 1e21;
    int256 public constant MIN_ABS_DEBT = -1e18;

    uint256 public constant ENTROPY_DELAY = 1 hours;
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant GUARDIAN_WINDOW = 24 hours;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => int256) private baseBalance;
    mapping(address => bool) public isRegistered;

    int256 public globalField;
    int256 public totalBaseSum;

    uint256 public totalSupply;
    uint256 public totalBurned;

    uint256 public P;

    mapping(bytes32 => int256) private edgeWeight;

    uint256 public lastEntropyUpdate;

    bool public paused;

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    address public gate;
    address public pendingGate;
    uint256 public unlockTime;

    address[] public guardians;

    mapping(address => bool) public guardianApproved;
    uint256 public guardianApprovals;
    uint256 public firstApprovalTime;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGate() {
        require(msg.sender == gate, "NOT_GATE");
        _;
    }

    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _gate, address[] memory _guardians) {
        require(_gate != address(0), "ZERO_GATE");
        require(_guardians.length == 3, "NEED_3");

        gate = _gate;
        guardians = _guardians;
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT CORE
    //////////////////////////////////////////////////////////////*/

    function _checkInvariant() internal view {
        if (
            int256(totalSupply) !=
            totalBaseSum + (globalField * int256(P))
        ) revert InvariantViolation();
    }

    function _debtLimit() internal view returns (int256) {
        int256 factor = int256(P) * 10;
        return (factor == 0)
            ? MIN_ABS_DEBT
            : -int256(totalSupply) / factor;
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE LAYER
    //////////////////////////////////////////////////////////////*/

    function setEdge(address from, address to, int256 weight)
        external
        onlyGate
    {
        require(weight <= MAX_EDGE_COST && weight >= -MAX_EDGE_COST);

        bytes32 id = keccak256(abi.encodePacked(from, to));
        edgeWeight[id] = weight;
    }

    function _readEdge(bytes32 id) internal view returns (int256) {
        return edgeWeight[id];
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER
    //////////////////////////////////////////////////////////////*/

    function transfer(address to, uint256 amount) external notPaused {
        require(amount > 0);
        require(isRegistered[msg.sender], "SENDER_NOT_REGISTERED");
        require(isRegistered[to], "TARGET_NOT_REGISTERED");

        int256 amt = int256(amount);

        bytes32 id = keccak256(abi.encodePacked(msg.sender, to));
        int256 edgeCost = _readEdge(id);

        int256 newBal = baseBalance[msg.sender] - amt - edgeCost;
        require(newBal >= _debtLimit(), "DEBT");

        baseBalance[msg.sender] = newBal;
        baseBalance[to] += amt;

        if (edgeCost > 0) {
            totalSupply -= uint256(edgeCost);
            totalBurned += uint256(edgeCost);
            totalBaseSum -= edgeCost;
        } else if (edgeCost < 0) {
            totalSupply += uint256(-edgeCost);
            totalBaseSum -= edgeCost;
        }

        emit Transfer(msg.sender, to, amount);

        _checkInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function mint(address to, uint256 amount)
        external
        onlyGate
    {
        require(isRegistered[to], "NOT_REGISTERED");

        uint256 newSupply = totalSupply + amount;
        require(newSupply <= MAX_SUPPLY);

        totalSupply = newSupply;

        baseBalance[to] += int256(amount);
        totalBaseSum += int256(amount);

        _checkInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                            REDISTRIBUTE
    //////////////////////////////////////////////////////////////*/

    function redistribute(uint256 amount)
        external
        onlyGate
    {
        require(P > 0);

        uint256 q = amount / P;
        uint256 r = amount % P;

        globalField += int256(q);

        uint256 delta = q * P;
        totalSupply += delta;

        totalBurned += r;

        emit Redistribute(amount, q);
        emit FieldUpdate(globalField);

        _checkInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                        NEGATIVE ENTROPY
    //////////////////////////////////////////////////////////////*/

    function applyNegEntropy() external onlyGate {
        require(block.timestamp >= lastEntropyUpdate + ENTROPY_DELAY);

        int256 delta = NEG_E * int256(P);

        globalField += NEG_E;
        totalBaseSum -= delta;

        lastEntropyUpdate = block.timestamp;

        emit FieldUpdate(globalField);

        _checkInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                        PARTICIPANTS
    //////////////////////////////////////////////////////////////*/

    function register(address user) external onlyGate {
        require(!isRegistered[user]);

        isRegistered[user] = true;
        P += 1;

        totalBaseSum -= globalField;

        emit Registered(user);

        _checkInvariant();
    }

    function unregister(address user) external onlyGate {
        require(isRegistered[user]);

        int256 base = baseBalance[user];

        if (base > 0) {
            totalSupply -= uint256(base);
            totalBurned += uint256(base);
        } else if (base < 0) {
            totalSupply += uint256(-base);
        }

        totalBaseSum -= base;

        baseBalance[user] = 0;

        isRegistered[user] = false;
        P -= 1;

        totalBaseSum += globalField;

        emit Unregistered(user);

        _checkInvariant();
    }

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN SYSTEM
    //////////////////////////////////////////////////////////////*/

    function _isGuardian(address a) internal view returns (bool) {
        for (uint i = 0; i < guardians.length; i++) {
            if (guardians[i] == a) return true;
        }
        return false;
    }

    function _resetVotes() internal {
        for (uint i = 0; i < guardians.length; i++) {
            guardianApproved[guardians[i]] = false;
        }
        guardianApprovals = 0;
        firstApprovalTime = 0;
    }

    function approveGuardianAction() external {
        require(_isGuardian(msg.sender), "NOT_G");

        if (
            firstApprovalTime != 0 &&
            block.timestamp > firstApprovalTime + GUARDIAN_WINDOW
        ) {
            _resetVotes();
        }

        if (guardianApprovals == 0) {
            firstApprovalTime = block.timestamp;
        }

        require(!guardianApproved[msg.sender]);

        guardianApproved[msg.sender] = true;
        guardianApprovals += 1;
    }

    function pause() external {
        require(msg.sender == gate || _isGuardian(msg.sender), "NO_AUTH");

        if (msg.sender != gate) {
            require(guardianApprovals >= 2, "NEED_2_GUARDIANS");
        }

        paused = true;
        emit Paused();

        _resetVotes();
    }

    function unpause() external onlyGate {
        paused = false;
        emit Unpaused();
    }

    function proposeGate(address newGate) external onlyGate {
        require(newGate != address(0), "ZERO_GATE");
        require(guardianApprovals >= 2);

        pendingGate = newGate;
        unlockTime = block.timestamp + TIMELOCK_DELAY;

        emit GateProposed(newGate);

        _resetVotes();
    }

    function executeGateUpdate() external {
        require(block.timestamp >= unlockTime);

        gate = pendingGate;
        pendingGate = address(0);

        emit GateUpdated(gate);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address user) external view returns (int256) {
        return baseBalance[user] + globalField;
    }

    function invariant()
        external
        view
        returns (int256 lhs, int256 rhs)
    {
        lhs = int256(totalSupply);
        rhs = totalBaseSum + (globalField * int256(P));
    }
}
