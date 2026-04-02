// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RFT_Core_Kardashev_Unit_V1
 * @notice Deterministic Field Integrity Core (RFT)
 */

contract RFT_Core_Kardashev_Unit_V1 {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvariantViolation();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int256 public constant NEG_E = -2718281828459045235;

    uint256 public constant MAX_SUPPLY = 1e27;
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant ENTROPY_DELAY = 1 hours;

    int256 public constant MIN_ABS_DEBT = -1e18;
    int256 public constant MAX_EDGE_COST = 1e21;

    uint256 public constant MINT_CAP_PER_DAY = 1e24;
    uint256 public constant GUARDIAN_WINDOW = 24 hours;

    uint256 public constant EXIT_BURN_BPS = 100;
    uint256 public constant BPS_DENOM = 10_000;

    /*//////////////////////////////////////////////////////////////
                                GOVERNED PARAMS
    //////////////////////////////////////////////////////////////*/

    int256 public minFieldThreshold = -1e26;
    uint256 public debtCoefficient = 10;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => int256) private baseBalance;

    int256 public globalField;

    uint256 public P;
    uint256 public totalSupply;
    uint256 public totalBurned;

    int256 public totalBaseSum;

    mapping(address => bool) public isRegistered;

    mapping(bytes32 => int256) private edgeWeight;
    mapping(bytes32 => uint256) public lastDecay;

    address public gate;
    address public pendingGate;
    uint256 public unlockTime;

    address[] public guardians;

    mapping(address => bool) public guardianApproved;
    uint256 public guardianApprovals;
    uint256 public firstApprovalTime;

    int256 public pendingMinFieldThreshold;
    uint256 public pendingDebtCoefficient;
    uint256 public policyUnlockTime;

    uint256 public lastEntropyUpdate;

    uint256 public lastMintTime;
    uint256 public mintedToday;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event FieldShift(int256 deltaField);
    event EntropySink(uint256 amount);
    event FlowUpdate(bytes32 indexed edgeId, int256 weight);
    event Mint(address indexed to, uint256 amount);

    event Register(address indexed user);
    event Unregister(address indexed user);

    event GateProposed(address indexed newGate, uint256 unlockTime);
    event GateUpdated(address indexed newGate);

    event PolicyProposed(int256 newFieldThreshold, uint256 newDebtCoeff, uint256 unlockTime);
    event PolicyEnacted(int256 newFieldThreshold, uint256 newDebtCoeff);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGate() {
        require(msg.sender == gate, "NOT_GATE");
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
                        INTERNAL CORE
    //////////////////////////////////////////////////////////////*/

    function _checkInvariantHard() internal view {
        if (
            int256(totalSupply) !=
            totalBaseSum + (globalField * int256(P))
        ) revert InvariantViolation();
    }

    function _debtLimit() internal view returns (int256) {
        int256 factor = int256(P) * int256(debtCoefficient);
        return (factor == 0)
            ? MIN_ABS_DEBT
            : -int256(totalSupply) / factor;
    }

    function _readEdge(bytes32 edgeId) internal view returns (int256) {
        return edgeWeight[edgeId];
    }

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

    /*//////////////////////////////////////////////////////////////
                            EDGE LAYER
    //////////////////////////////////////////////////////////////*/

    function decayEdge(bytes32 edgeId) external {
        require(block.timestamp >= lastDecay[edgeId] + 1 days, "TOO_FAST");
        lastDecay[edgeId] = block.timestamp;

        int256 w = edgeWeight[edgeId];
        edgeWeight[edgeId] = (w * 99) / 100;
    }

    function setEdge(address from, address to, int256 weight)
        external
        onlyGate
    {
        require(weight <= MAX_EDGE_COST && weight >= -MAX_EDGE_COST, "EDGE_LIMIT");

        bytes32 id = keccak256(abi.encodePacked(from, to));
        edgeWeight[id] = weight;

        emit FlowUpdate(id, weight);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER
    //////////////////////////////////////////////////////////////*/

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "ZERO");
        require(amount > 0, "ZERO");

        int256 amt = int256(amount);

        bytes32 id = keccak256(abi.encodePacked(msg.sender, to));
        int256 edgeCost = _readEdge(id);

        if (edgeCost > MAX_EDGE_COST) edgeCost = MAX_EDGE_COST;
        if (edgeCost < -MAX_EDGE_COST) edgeCost = -MAX_EDGE_COST;

        int256 newBal = baseBalance[msg.sender] - amt - edgeCost;

        require(newBal >= _debtLimit(), "DEBT");

        baseBalance[msg.sender] = newBal;
        baseBalance[to] += amt;

        _checkInvariantHard();

        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                MINT
    //////////////////////////////////////////////////////////////*/

    function mint(address to, uint256 amount)
        external
        onlyGate
    {
        if (block.timestamp >= lastMintTime + 1 days) {
            lastMintTime = block.timestamp;
            mintedToday = 0;
        }

        require(mintedToday + amount <= MINT_CAP_PER_DAY, "CAP_EXCEEDED");

        mintedToday += amount;

        uint256 newSupply = totalSupply + amount;
        require(newSupply <= MAX_SUPPLY, "MAX");

        totalSupply = newSupply;

        baseBalance[to] += int256(amount);
        totalBaseSum += int256(amount);

        _checkInvariantHard();

        emit Mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            REDISTRIBUTE
    //////////////////////////////////////////////////////////////*/

    function redistribute(uint256 amount)
        external
        onlyGate
    {
        require(P > 0, "NO_P");

        uint256 q = amount / P;
        uint256 r = amount % P;

        globalField += int256(q);
        totalBurned += r;

        _checkInvariantHard();

        emit FieldShift(int256(q));
        emit EntropySink(r);
    }

    /*//////////////////////////////////////////////////////////////
                        NEG ENTROPY
    //////////////////////////////////////////////////////////////*/

    function applyNegEntropy() external onlyGate {
        require(block.timestamp >= lastEntropyUpdate + ENTROPY_DELAY, "RATE");
        require(globalField + NEG_E >= minFieldThreshold, "DECAY");

        int256 delta = NEG_E * int256(P);

        globalField += NEG_E;
        totalBaseSum -= delta;

        lastEntropyUpdate = block.timestamp;

        _checkInvariantHard();

        emit FieldShift(NEG_E);
    }

    /*//////////////////////////////////////////////////////////////
                        PARTICIPANTS (CRITICAL)
    //////////////////////////////////////////////////////////////*/

    function register(address user) external onlyGate {
        require(!isRegistered[user], "ALREADY");

        isRegistered[user] = true;
        P += 1;

        emit Register(user);
    }

    function unregister(address user) external onlyGate {
        require(isRegistered[user], "NOT_REG");
        require(P > 0, "UNDERFLOW");

        int256 base = baseBalance[user];

        if (base > 0) {
            int256 burn = (base * int256(EXIT_BURN_BPS)) / int256(BPS_DENOM);

            totalSupply -= uint256(burn);
            totalBurned += uint256(burn);

            totalBaseSum -= burn;
            base -= burn;

            totalBaseSum -= base;
        } else if (base < 0) {
            totalBaseSum -= base;
            totalSupply += uint256(-base);
        }

        baseBalance[user] = 0;

        isRegistered[user] = false;
        P -= 1;

        totalBaseSum += globalField;

        _checkInvariantHard();

        emit Unregister(user);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function approveGateChange() external {
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

        require(!guardianApproved[msg.sender], "DUP");

        guardianApproved[msg.sender] = true;
        guardianApprovals += 1;
    }

    function proposeGate(address newGate) external onlyGate {
        require(guardianApprovals >= 2, "2/3");

        pendingGate = newGate;
        unlockTime = block.timestamp + TIMELOCK_DELAY;

        _resetVotes();

        emit GateProposed(newGate, unlockTime);
    }

    function executeGateUpdate() external {
        require(block.timestamp >= unlockTime, "TIMELOCK");

        gate = pendingGate;
        pendingGate = address(0);

        emit GateUpdated(gate);
    }

    function proposePolicy(
        int256 newFieldThreshold,
        uint256 newDebtCoeff
    ) external onlyGate {

        pendingMinFieldThreshold = newFieldThreshold;
        pendingDebtCoefficient = newDebtCoeff;

        policyUnlockTime = block.timestamp + TIMELOCK_DELAY;

        emit PolicyProposed(newFieldThreshold, newDebtCoeff, policyUnlockTime);
    }

    function enactPolicy() external {
        require(block.timestamp >= policyUnlockTime, "TIMELOCK");

        minFieldThreshold = pendingMinFieldThreshold;
        debtCoefficient = pendingDebtCoefficient;

        emit PolicyEnacted(minFieldThreshold, debtCoefficient);
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