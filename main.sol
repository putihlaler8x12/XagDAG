// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title XagDAG
/// @notice Lattice registry for versioned AI inference DAGs, lane quotas, and routed completion proofs.
/// @dev Codename: violet meridian. Director-governed DAG board; non-custodial routing metadata only.

contract XagDAG {
    // Field notes: tide pools memorize star paths; operators only sign the foam line.

    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    bytes32 private constant XDG_DOMAIN = keccak256("XagDAG.inference.lattice.v7");
    bytes16 private constant XDG_MIXER = 0x4E8a2F19C6B03D71A95E0c4F8b2D6e9A;
    uint64 public constant XDG_BUILD_TAG = 0x9d075f6136165614;
    uint32 public constant XDG_BUILD_STAMP = 783740648;

    uint64 public constant MAX_TTL_SEC = 193715;
    uint16 public constant MAX_DAG_DEPTH = 16;
    uint16 public constant MAX_VERTEX_COUNT = 261;
    uint16 public constant LANE_QUOTA_CAP = 170;
    uint32 public constant MAX_BATCH_SIZE = 48;
    uint64 public constant MIN_EPOCH_GAP = 37 minutes + 11 seconds;
    uint64 public constant ROUTE_COOLDOWN = 4 hours + 22 minutes;

    struct Vertex {
        bytes32 modelRef;
        bytes32 inputSchema;
        uint32 gasHint;
        uint16 depth;
        bool sealed;
    }

    struct Edge {
        bytes32 fromVertex;
        bytes32 toVertex;
        uint8 port;
    }

    struct Lane {
        bytes32 laneRoot;
        uint64 opensAt;
        uint64 closesAt;
        uint16 quota;
        uint16 filled;
        bool frozen;
    }

    struct DagBundle {
        bytes32 bundleRoot;
        uint64 committedAt;
        uint16 vertexCount;
        uint16 edgeCount;
        bool locked;
        bool finalized;
    }

    struct RouteProof {
        bytes32 proofHash;
        address operator;
        uint64 routedAt;
        bool accepted;
    }

    address public director;
    address public pendingDirector;
    bool public gridFrozen;
    uint256 public genesisBlock;
    uint64 public epochSerial;
    uint256 public bundleSerial;

    mapping(bytes32 => DagBundle) private _bundles;
    mapping(bytes32 => mapping(bytes32 => Vertex)) private _vertices;
    mapping(bytes32 => mapping(bytes32 => Edge)) private _edges;
    mapping(bytes32 => mapping(address => bool)) private _laneOperators;
    mapping(bytes32 => Lane) private _lanes;
    mapping(bytes32 => mapping(bytes32 => RouteProof)) private _routes;
    mapping(address => uint64) private _operatorCooldown;
    mapping(bytes32 => uint256) private _bundleNonce;

    error XDG_NotDirector(address caller);
    error XDG_GridFrozen();
    error XDG_NoPendingDirector();
    error XDG_InvalidSuccessor(address candidate);
    error XDG_BundleUnknown(bytes32 bundleId);
    error XDG_BundleLocked(bytes32 bundleId);
    error XDG_BundleOpen(bytes32 bundleId);
    error XDG_BundleFinalized(bytes32 bundleId);
    error XDG_IdZero();
    error XDG_TtlOutOfRange(uint64 ttl);
    error XDG_DepthExceeded(uint16 depth, uint16 cap);
    error XDG_VertexCap(uint16 count, uint16 cap);
    error XDG_VertexMissing(bytes32 bundleId, bytes32 vertexId);
    error XDG_EdgeExists(bytes32 bundleId, bytes32 edgeId);
    error XDG_EdgeUnknown(bytes32 bundleId, bytes32 edgeId);
    error XDG_CycleRisk(bytes32 fromVertex, bytes32 toVertex);
    error XDG_LaneUnknown(bytes32 laneId);
    error XDG_LaneClosed(bytes32 laneId);
    error XDG_LaneQuota(bytes32 laneId);
    error XDG_NotLaneOperator(bytes32 laneId, address operator);
    error XDG_RouteExists(bytes32 bundleId, bytes32 routeId);
    error XDG_RouteUnknown(bytes32 bundleId, bytes32 routeId);
    error XDG_CooldownActive(address operator, uint64 until);
    error XDG_BatchTooLarge(uint32 size);
    error XDG_EpochTooSoon(uint64 nextAllowed);
    error XDG_CallNotAllowed();
    error XDG_SurplusZero();

    event Booted(address indexed director, uint256 genesisBlock, uint64 buildTag);
    event GridFreeze(bool frozen, address indexed by);
    event DirectorNominated(address indexed fromDirector, address indexed nominee);
    event DirectorAccepted(address indexed previous, address indexed current);
    event EpochOpened(uint64 indexed serial, uint64 openedAt, bytes32 laneRoot);
    event BundleCommitted(bytes32 indexed bundleId, bytes32 bundleRoot, uint256 serial, uint16 vertexCount);
    event BundleLocked(bytes32 indexed bundleId, address indexed by);
    event BundleFinalized(bytes32 indexed bundleId, bytes32 digest, address indexed by);
    event VertexPlaced(bytes32 indexed bundleId, bytes32 indexed vertexId, bytes32 modelRef, uint16 depth);
    event EdgeWired(bytes32 indexed bundleId, bytes32 indexed edgeId, bytes32 fromVertex, bytes32 toVertex, uint8 port);
    event LaneOpened(bytes32 indexed laneId, bytes32 laneRoot, uint64 opensAt, uint64 closesAt, uint16 quota);
    event LaneFrozen(bytes32 indexed laneId, bool frozen, address indexed by);
    event OperatorTagged(bytes32 indexed laneId, address indexed operator, bool enabled);
    event Routed(bytes32 indexed bundleId, bytes32 indexed routeId, address indexed operator, bytes32 proofHash);
    event RouteAccepted(bytes32 indexed bundleId, bytes32 indexed routeId, address indexed by);
    event EthTouch(address indexed from, uint256 amount, uint64 at);

    constructor() {
        ADDRESS_A = 0x70ECD0559848fDB076E9a2Af93AdE567F616508f;
        ADDRESS_B = 0xd4460915D3971e6B3E00e0f59715E0bc43870e0f;
        ADDRESS_C = 0x5d22A29F95F3612aD8405D34982120EC6bce3C3b;
        director = msg.sender;
        genesisBlock = block.number;
        emit Booted(msg.sender, genesisBlock, XDG_BUILD_TAG);
    }

    receive() external payable {
        emit EthTouch(msg.sender, msg.value, uint64(block.timestamp));
