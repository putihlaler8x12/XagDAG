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
    }

    fallback() external payable {
        revert XDG_CallNotAllowed();
    }

    modifier onlyDirector() {
        if (msg.sender != director) revert XDG_NotDirector(msg.sender);
        _;
    }

    modifier whenUnfrozen() {
        if (gridFrozen) revert XDG_GridFrozen();
        _;
    }

    function nominateDirector(address nominee) external onlyDirector {
        if (nominee == address(0)) revert XDG_InvalidSuccessor(nominee);
        pendingDirector = nominee;
        emit DirectorNominated(director, nominee);
    }

    function acceptDirector() external {
        if (pendingDirector == address(0)) revert XDG_NoPendingDirector();
        if (msg.sender != pendingDirector) revert XDG_NotDirector(msg.sender);
        address prev = director;
        director = pendingDirector;
        pendingDirector = address(0);
        emit DirectorAccepted(prev, director);
    }

    function setGridFrozen(bool frozen) external onlyDirector {
        gridFrozen = frozen;
        emit GridFreeze(frozen, msg.sender);
    }

    function openEpoch(bytes32 laneRoot) external onlyDirector whenUnfrozen {
        if (laneRoot == bytes32(0)) revert XDG_IdZero();
        unchecked {
            epochSerial += 1;
        }
        emit EpochOpened(epochSerial, uint64(block.timestamp), laneRoot);
    }

    function commitBundle(bytes32 bundleId, bytes32 bundleRoot) external onlyDirector whenUnfrozen {
        if (bundleId == bytes32(0) || bundleRoot == bytes32(0)) revert XDG_IdZero();
        DagBundle storage B = _bundles[bundleId];
        if (B.committedAt != 0) revert XDG_BundleOpen(bundleId);
        B.bundleRoot = bundleRoot;
        B.committedAt = uint64(block.timestamp);
        unchecked {
            bundleSerial += 1;
            _bundleNonce[bundleId] = bundleSerial;
        }
        emit BundleCommitted(bundleId, bundleRoot, bundleSerial, 0);
    }

    function lockBundle(bytes32 bundleId) external onlyDirector whenUnfrozen {
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        B.locked = true;
        emit BundleLocked(bundleId, msg.sender);
    }

    function finalizeBundle(bytes32 bundleId) external onlyDirector whenUnfrozen {
        DagBundle storage B = _requireBundle(bundleId);
        if (!B.locked) revert XDG_BundleOpen(bundleId);
        if (B.finalized) revert XDG_BundleFinalized(bundleId);
        B.finalized = true;
        emit BundleFinalized(bundleId, bundleDigest(bundleId), msg.sender);
    }

    function placeVertex(
        bytes32 bundleId,
        bytes32 vertexId,
        bytes32 modelRef,
        bytes32 inputSchema,
        uint32 gasHint,
        uint16 depth
    ) external onlyDirector whenUnfrozen {
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        if (vertexId == bytes32(0) || modelRef == bytes32(0)) revert XDG_IdZero();
        if (depth > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depth, MAX_DAG_DEPTH);
        if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
        if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);

        _vertices[bundleId][vertexId] = Vertex({
            modelRef: modelRef,
            inputSchema: inputSchema,
            gasHint: gasHint,
            depth: depth,
            sealed: false
        });
        unchecked {
            B.vertexCount += 1;
        }
        emit VertexPlaced(bundleId, vertexId, modelRef, depth);
    }

    function wireEdge(
        bytes32 bundleId,
        bytes32 edgeId,
        bytes32 fromVertex,
        bytes32 toVertex,
        uint8 port
    ) external onlyDirector whenUnfrozen {
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        if (edgeId == bytes32(0) || fromVertex == bytes32(0) || toVertex == bytes32(0)) revert XDG_IdZero();
        if (_edges[bundleId][edgeId].fromVertex != bytes32(0)) revert XDG_EdgeExists(bundleId, edgeId);
        if (_vertices[bundleId][fromVertex].modelRef == bytes32(0)) revert XDG_VertexMissing(bundleId, fromVertex);
        if (_vertices[bundleId][toVertex].modelRef == bytes32(0)) revert XDG_VertexMissing(bundleId, toVertex);
        if (fromVertex == toVertex) revert XDG_CycleRisk(fromVertex, toVertex);

        _edges[bundleId][edgeId] = Edge({fromVertex: fromVertex, toVertex: toVertex, port: port});
        unchecked {
            B.edgeCount += 1;
        }
        emit EdgeWired(bundleId, edgeId, fromVertex, toVertex, port);
    }

    function openLane(bytes32 laneId, bytes32 laneRoot, uint64 ttlSec, uint16 quota) external onlyDirector whenUnfrozen {
        if (laneId == bytes32(0) || laneRoot == bytes32(0)) revert XDG_IdZero();
        if (ttlSec == 0 || ttlSec > MAX_TTL_SEC) revert XDG_TtlOutOfRange(ttlSec);
        if (quota == 0 || quota > LANE_QUOTA_CAP) revert XDG_LaneQuota(laneId);
        if (_lanes[laneId].opensAt != 0) revert XDG_BundleOpen(laneId);

        uint64 opensAt = uint64(block.timestamp);
        uint64 closesAt = opensAt + ttlSec;
        _lanes[laneId] = Lane({
            laneRoot: laneRoot,
            opensAt: opensAt,
            closesAt: closesAt,
            quota: quota,
            filled: 0,
            frozen: false
        });
        emit LaneOpened(laneId, laneRoot, opensAt, closesAt, quota);
    }

    function setLaneFrozen(bytes32 laneId, bool frozen) external onlyDirector {
        Lane storage L = _requireLane(laneId);
        L.frozen = frozen;
        emit LaneFrozen(laneId, frozen, msg.sender);
    }

    function tagLaneOperator(bytes32 laneId, address operator, bool enabled) external onlyDirector {
        _requireLane(laneId);
        _laneOperators[laneId][operator] = enabled;
        emit OperatorTagged(laneId, operator, enabled);
    }

    function routeProof(bytes32 bundleId, bytes32 routeId, bytes32 proofHash) external whenUnfrozen {
        if (routeId == bytes32(0) || proofHash == bytes32(0)) revert XDG_IdZero();
        DagBundle storage B = _requireBundle(bundleId);
        if (!B.locked || B.finalized) revert XDG_BundleLocked(bundleId);
        if (_routes[bundleId][routeId].routedAt != 0) revert XDG_RouteExists(bundleId, routeId);

        uint64 nowTs = uint64(block.timestamp);
        uint64 untilTs = _operatorCooldown[msg.sender];
        if (nowTs < untilTs) revert XDG_CooldownActive(msg.sender, untilTs);

        _routes[bundleId][routeId] = RouteProof({
            proofHash: proofHash,
            operator: msg.sender,
            routedAt: nowTs,
            accepted: false
        });
        _operatorCooldown[msg.sender] = nowTs + ROUTE_COOLDOWN;
        emit Routed(bundleId, routeId, msg.sender, proofHash);
    }

    function acceptRoute(bytes32 bundleId, bytes32 routeId) external onlyDirector whenUnfrozen {
        RouteProof storage R = _routes[bundleId][routeId];
        if (R.routedAt == 0) revert XDG_RouteUnknown(bundleId, routeId);
        if (R.accepted) revert XDG_RouteExists(bundleId, routeId);
        R.accepted = true;
        emit RouteAccepted(bundleId, routeId, msg.sender);
    }

    function reclaimSurplus(address payable to) external onlyDirector {
        if (to == address(0)) revert XDG_InvalidSuccessor(to);
        uint256 bal = address(this).balance;
        if (bal == 0) revert XDG_SurplusZero();
        (bool ok,) = to.call{value: bal}("");
        require(ok);
    }

    function bundleDigest(bytes32 bundleId) public view returns (bytes32) {
        DagBundle memory B = _bundles[bundleId];
        if (B.committedAt == 0) revert XDG_BundleUnknown(bundleId);
        return keccak256(
            abi.encode(
                XDG_DOMAIN,
                XDG_MIXER,
                bundleId,
                B.bundleRoot,
                B.vertexCount,
                B.edgeCount,
                B.locked,
                B.finalized,
                genesisBlock,
                epochSerial,
                bundleSerial,
                director,
                ADDRESS_A,
                ADDRESS_B,
                ADDRESS_C,
                XDG_BUILD_TAG,
                XDG_BUILD_STAMP
            )
        );
    }

    function bundleView(bytes32 bundleId)
        external
        view
        returns (bytes32 bundleRoot, uint64 committedAt, uint16 vertexCount, uint16 edgeCount, bool locked, bool finalized)
    {
        DagBundle memory B = _bundles[bundleId];
        if (B.committedAt == 0) revert XDG_BundleUnknown(bundleId);
        return (B.bundleRoot, B.committedAt, B.vertexCount, B.edgeCount, B.locked, B.finalized);
    }

    function vertexView(bytes32 bundleId, bytes32 vertexId)
        external
        view
        returns (bytes32 modelRef, bytes32 inputSchema, uint32 gasHint, uint16 depth, bool sealed)
    {
        Vertex memory V = _vertices[bundleId][vertexId];
        if (V.modelRef == bytes32(0)) revert XDG_VertexMissing(bundleId, vertexId);
        return (V.modelRef, V.inputSchema, V.gasHint, V.depth, V.sealed);
    }

    function edgeView(bytes32 bundleId, bytes32 edgeId)
        external
        view
        returns (bytes32 fromVertex, bytes32 toVertex, uint8 port)
    {
        Edge memory E = _edges[bundleId][edgeId];
        if (E.fromVertex == bytes32(0)) revert XDG_EdgeUnknown(bundleId, edgeId);
        return (E.fromVertex, E.toVertex, E.port);
    }

    function laneView(bytes32 laneId)
        external
        view
        returns (bytes32 laneRoot, uint64 opensAt, uint64 closesAt, uint16 quota, uint16 filled, bool frozen)
    {
        Lane memory L = _lanes[laneId];
        if (L.opensAt == 0) revert XDG_LaneUnknown(laneId);
        return (L.laneRoot, L.opensAt, L.closesAt, L.quota, L.filled, L.frozen);
    }

    function routeView(bytes32 bundleId, bytes32 routeId)
        external
        view
        returns (bytes32 proofHash, address operator, uint64 routedAt, bool accepted)
    {
        RouteProof memory R = _routes[bundleId][routeId];
        if (R.routedAt == 0) revert XDG_RouteUnknown(bundleId, routeId);
        return (R.proofHash, R.operator, R.routedAt, R.accepted);
    }

    function isLaneOperator(bytes32 laneId, address operator) external view returns (bool) {
        return _laneOperators[laneId][operator];
    }

    function operatorCooldown(address operator) external view returns (uint64) {
        return _operatorCooldown[operator];
    }

    function bundleNonce(bytes32 bundleId) external view returns (uint256) {
        return _bundleNonce[bundleId];
    }

    function _requireBundle(bytes32 bundleId) private view returns (DagBundle storage B) {
        B = _bundles[bundleId];
        if (B.committedAt == 0) revert XDG_BundleUnknown(bundleId);
    }

    function _requireLane(bytes32 laneId) private view returns (Lane storage L) {
        L = _lanes[laneId];
        if (L.opensAt == 0) revert XDG_LaneUnknown(laneId);
    }

    function batchPlaceVertices_1(
        bytes32 bundleId,
        bytes32[1] calldata vertexIds,
        bytes32[1] calldata modelRefs,
        bytes32[1] calldata inputSchemas,
        uint32[1] calldata gasHints,
        uint16[1] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (1 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(1);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 1; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_2(
        bytes32 bundleId,
        bytes32[2] calldata vertexIds,
        bytes32[2] calldata modelRefs,
        bytes32[2] calldata inputSchemas,
        uint32[2] calldata gasHints,
        uint16[2] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (2 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(2);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 2; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_3(
        bytes32 bundleId,
        bytes32[3] calldata vertexIds,
        bytes32[3] calldata modelRefs,
        bytes32[3] calldata inputSchemas,
        uint32[3] calldata gasHints,
        uint16[3] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (3 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(3);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 3; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_4(
        bytes32 bundleId,
        bytes32[4] calldata vertexIds,
        bytes32[4] calldata modelRefs,
        bytes32[4] calldata inputSchemas,
        uint32[4] calldata gasHints,
        uint16[4] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (4 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(4);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 4; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_5(
        bytes32 bundleId,
        bytes32[5] calldata vertexIds,
        bytes32[5] calldata modelRefs,
        bytes32[5] calldata inputSchemas,
        uint32[5] calldata gasHints,
        uint16[5] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (5 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(5);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 5; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_6(
        bytes32 bundleId,
        bytes32[6] calldata vertexIds,
        bytes32[6] calldata modelRefs,
        bytes32[6] calldata inputSchemas,
        uint32[6] calldata gasHints,
        uint16[6] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (6 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(6);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 6; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_7(
        bytes32 bundleId,
        bytes32[7] calldata vertexIds,
        bytes32[7] calldata modelRefs,
        bytes32[7] calldata inputSchemas,
        uint32[7] calldata gasHints,
        uint16[7] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (7 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(7);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 7; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_8(
        bytes32 bundleId,
        bytes32[8] calldata vertexIds,
        bytes32[8] calldata modelRefs,
        bytes32[8] calldata inputSchemas,
        uint32[8] calldata gasHints,
        uint16[8] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (8 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(8);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 8; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_9(
        bytes32 bundleId,
        bytes32[9] calldata vertexIds,
        bytes32[9] calldata modelRefs,
        bytes32[9] calldata inputSchemas,
        uint32[9] calldata gasHints,
        uint16[9] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (9 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(9);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 9; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_10(
        bytes32 bundleId,
        bytes32[10] calldata vertexIds,
        bytes32[10] calldata modelRefs,
        bytes32[10] calldata inputSchemas,
        uint32[10] calldata gasHints,
        uint16[10] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (10 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(10);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 10; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_11(
        bytes32 bundleId,
        bytes32[11] calldata vertexIds,
        bytes32[11] calldata modelRefs,
        bytes32[11] calldata inputSchemas,
        uint32[11] calldata gasHints,
        uint16[11] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (11 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(11);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 11; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_12(
        bytes32 bundleId,
        bytes32[12] calldata vertexIds,
        bytes32[12] calldata modelRefs,
        bytes32[12] calldata inputSchemas,
        uint32[12] calldata gasHints,
        uint16[12] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (12 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(12);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 12; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_13(
        bytes32 bundleId,
        bytes32[13] calldata vertexIds,
        bytes32[13] calldata modelRefs,
        bytes32[13] calldata inputSchemas,
        uint32[13] calldata gasHints,
        uint16[13] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (13 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(13);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 13; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_14(
        bytes32 bundleId,
        bytes32[14] calldata vertexIds,
        bytes32[14] calldata modelRefs,
        bytes32[14] calldata inputSchemas,
        uint32[14] calldata gasHints,
        uint16[14] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (14 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(14);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 14; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_15(
        bytes32 bundleId,
        bytes32[15] calldata vertexIds,
        bytes32[15] calldata modelRefs,
        bytes32[15] calldata inputSchemas,
        uint32[15] calldata gasHints,
        uint16[15] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (15 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(15);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 15; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_16(
        bytes32 bundleId,
        bytes32[16] calldata vertexIds,
        bytes32[16] calldata modelRefs,
        bytes32[16] calldata inputSchemas,
        uint32[16] calldata gasHints,
        uint16[16] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (16 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(16);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 16; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
            unchecked { B.vertexCount += 1; }
            emit VertexPlaced(bundleId, vertexId, modelRefs[i], depths[i]);
        }
    }
    function batchPlaceVertices_17(
        bytes32 bundleId,
        bytes32[17] calldata vertexIds,
        bytes32[17] calldata modelRefs,
        bytes32[17] calldata inputSchemas,
        uint32[17] calldata gasHints,
        uint16[17] calldata depths
    ) external onlyDirector whenUnfrozen {
        if (17 > MAX_BATCH_SIZE) revert XDG_BatchTooLarge(17);
        DagBundle storage B = _requireBundle(bundleId);
        if (B.locked) revert XDG_BundleLocked(bundleId);
        for (uint256 i; i < 17; ++i) {
            bytes32 vertexId = vertexIds[i];
            if (vertexId == bytes32(0)) revert XDG_IdZero();
            if (depths[i] > MAX_DAG_DEPTH) revert XDG_DepthExceeded(depths[i], MAX_DAG_DEPTH);
            if (B.vertexCount >= MAX_VERTEX_COUNT) revert XDG_VertexCap(B.vertexCount, MAX_VERTEX_COUNT);
            if (_vertices[bundleId][vertexId].modelRef != bytes32(0)) revert XDG_BundleOpen(bundleId);
            _vertices[bundleId][vertexId] = Vertex({
                modelRef: modelRefs[i],
                inputSchema: inputSchemas[i],
                gasHint: gasHints[i],
                depth: depths[i],
                sealed: false
            });
