// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Stands in for the TapeOut processor factory.
contract MockFactory {
    mapping(address => bool) public isCPU;

    function setCPU(address p, bool on) external {
        isCPU[p] = on;
    }
}

/// @notice Stands in for a TapeOut processor. Each circuit id answers `eval` from a stored list:
/// the answer for input bytes `x` is `outs[id][x read as an LSB-first number]`.
contract MockProcessor {
    struct Info {
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
    }

    mapping(uint256 => Info) internal info;
    mapping(uint256 => bytes) internal net;
    mapping(uint256 => address) internal owner;
    mapping(uint256 => bytes[]) internal outs;
    mapping(uint256 => bool) public revertEval;
    mapping(uint256 => bool) public burnGasEval;
    mapping(uint256 => uint256) public evalGasCost; // extra gas eval burns before answering (0 = none)

    function setCircuit(uint256 id, address who, uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) external {
        owner[id] = who;
        info[id] = Info(nIn, nOut, nState, gates);
        net[id] = abi.encodePacked("netlist", id, gates);
    }

    function setOuts(uint256 id, bytes[] calldata o) external {
        delete outs[id];
        for (uint256 i = 0; i < o.length; ++i) {
            outs[id].push(o[i]);
        }
    }

    function setOut(uint256 id, uint256 c, bytes calldata o) external {
        outs[id][c] = o;
    }

    function setNetlist(uint256 id, bytes calldata n) external {
        net[id] = n;
    }

    function setGateCount(uint256 id, uint32 g) external {
        info[id].gateCount = g;
    }

    function setOwner(uint256 id, address who) external {
        owner[id] = who;
    }

    function setRevertEval(uint256 id, bool on) external {
        revertEval[id] = on;
    }

    function setBurnGasEval(uint256 id, bool on) external {
        burnGasEval[id] = on;
    }

    /// Make eval burn about `cost` gas before answering, like a circuit that costs that much to run.
    function setEvalGasCost(uint256 id, uint256 cost) external {
        evalGasCost[id] = cost;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = owner[id];
        require(o != address(0), "ERC721NonexistentToken");
        return o;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Info memory i = info[id];
        return (i.nIn, i.nOut, i.nState, i.gateCount);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return net[id];
    }

    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory) {
        require(!revertEval[id], "eval reverted");
        if (burnGasEval[id]) {
            // Spin until out of gas, like a circuit far too big for the gas given.
            uint256 x;
            while (true) {
                x++;
            }
        }
        uint256 cost = evalGasCost[id];
        if (cost > 0) {
            // If cost is more than the gas left, this spins until out of gas.
            uint256 stopAt = gasleft() > cost ? gasleft() - cost : 0;
            while (gasleft() > stopAt) {}
        }
        require(info[id].nState == 0, "has latch: use step");
        uint256 c;
        for (uint256 i = 0; i < inputs.length; ++i) {
            c |= uint256(uint8(inputs[i])) << (8 * i);
        }
        return outs[id][c];
    }
}
