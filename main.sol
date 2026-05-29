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
