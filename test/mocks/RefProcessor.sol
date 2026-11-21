// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProcessor} from "../../src/ITapeOut.sol";

/// @notice Stands in for a TapeOut processor that really runs netlists made of NAND (0x00) and REF (0x02) records,
/// with the TAP-02 layout (no header, big-endian; wires 0 and 1 are constants, inputs from 2, then each record's
/// outputs in order; the outputs are the last nOut wires). A REF runs the referenced circuit with eval on its
/// processor, so a top made of REFs to mock pieces computes what those pieces compute. No LATCH, no memory.
/// mint stores a netlist with its nIn / nOut and computes the gate count the way TapeOut reports it (NANDs plus
/// every referenced circuit's gate count). No access control and no checks: test and local-anvil use only.
contract RefProcessor {
    struct Info {
        uint32 nIn;
        uint32 nOut;
        uint32 gateCount;
    }

    uint256 public lastId;
    mapping(uint256 => Info) internal info;
    mapping(uint256 => bytes) internal net;
    mapping(uint256 => address) internal owner;

    /// Store `nl` as a new circuit owned by `who`; returns its id (1, 2, ...).
    function mint(bytes calldata nl, uint32 nIn, uint32 nOut, address who) external returns (uint256 id) {
        id = ++lastId;
        net[id] = nl;
        owner[id] = who;
        info[id] = Info(nIn, nOut, _gates(nl));
    }

    /// Change a stored netlist (stands in for an upgrade that changes a circuit under an order).
    function setNetlist(uint256 id, bytes calldata nl) external {
        net[id] = nl;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = owner[id];
        require(o != address(0), "ERC721NonexistentToken");
        return o;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Info memory i = info[id];
        return (i.nIn, i.nOut, 0, i.gateCount);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return net[id];
    }

    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory out) {
        Info memory inf = info[id];
        require(owner[id] != address(0), "no circuit");
        bytes memory nl = net[id];
        uint8[] memory s = new uint8[](2 + inf.nIn + _produced(nl));
        s[1] = 1;
        for (uint256 i = 0; i < inf.nIn; ++i) {
            s[2 + i] = uint8(inputs[i / 8]) >> (i % 8) & 1;
        }
        uint256 next = 2 + inf.nIn;
        uint256 at;
        while (at < nl.length) {
            if (uint8(nl[at]) == 0) {
                s[next++] = 1 - (s[_u(nl, at + 1, 3)] & s[_u(nl, at + 4, 3)]);
                at += 7;
            } else {
                require(uint8(nl[at]) == 2, "bad opcode");
                (at, next) = _ref(nl, at, s, next);
            }
        }
        out = new bytes((inf.nOut + 7) / 8);
        for (uint256 j = 0; j < inf.nOut; ++j) {
            if (s[next - inf.nOut + j] == 1) out[j / 8] = bytes1(uint8(out[j / 8]) | uint8(1 << (j % 8)));
        }
    }

    function _ref(bytes memory nl, uint256 at, uint8[] memory s, uint256 next) internal view returns (uint256, uint256) {
        address cpu = address(uint160(_u(nl, at + 1, 20)));
        uint256 cid = _u(nl, at + 21, 8);
        uint256 nIns = uint8(nl[at + 29]);
        uint256 nOuts = uint8(nl[at + 30]);
        bytes memory x = new bytes((nIns + 7) / 8);
        for (uint256 i = 0; i < nIns; ++i) {
            if (s[_u(nl, at + 31 + 3 * i, 3)] == 1) x[i / 8] = bytes1(uint8(x[i / 8]) | uint8(1 << (i % 8)));
        }
        bytes memory y = IProcessor(cpu).eval(cid, x);
        for (uint256 j = 0; j < nOuts; ++j) {
            s[next++] = uint8(y[j / 8]) >> (j % 8) & 1;
        }
        return (at + 31 + 3 * nIns, next);
    }

    /// Wires the records create.
    function _produced(bytes memory nl) internal pure returns (uint256 p) {
        uint256 at;
        while (at < nl.length) {
            if (uint8(nl[at]) == 0) {
                p += 1;
                at += 7;
            } else {
                p += uint8(nl[at + 30]);
                at += 31 + 3 * uint256(uint8(nl[at + 29]));
            }
        }
    }

    function _gates(bytes memory nl) internal view returns (uint32 g) {
        uint256 at;
        while (at < nl.length) {
            if (uint8(nl[at]) == 0) {
                g += 1;
                at += 7;
            } else {
                (,,, uint32 sub) = IProcessor(address(uint160(_u(nl, at + 1, 20)))).circuitInfo(_u(nl, at + 21, 8));
                g += sub;
                at += 31 + 3 * uint256(uint8(nl[at + 29]));
            }
        }
    }

    /// Big-endian unsigned number of `size` bytes at `at`.
    function _u(bytes memory b, uint256 at, uint256 size) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < size; ++i) {
            v = (v << 8) | uint8(b[at + i]);
        }
    }
}
