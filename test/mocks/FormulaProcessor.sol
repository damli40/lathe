// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Stands in for a TapeOut processor whose circuits compute a >= b or a + b on the fly, so 16- and 17-input
/// circuits need no 65,536-entry answer list. Input layout matches FormulaLib: the inputs read as an LSB-first
/// number x; a = the low widthA bits of x, b = the next widthB bits. Outputs are packed LSB first.
/// `wrongAt` makes one case answer wrong (bit 0 flipped) so rejection can be tested; `evalGasCost` burns gas like
/// a real circuit of that size would. No access control: test and local-anvil use only, never deployed for real.
contract FormulaProcessor {
    struct Info {
        bool add; // false = GreaterOrEqual
        uint8 widthA;
        uint8 widthB;
        uint32 gateCount;
    }

    mapping(uint256 => Info) internal info;
    mapping(uint256 => address) internal owner;
    mapping(uint256 => bytes) internal net;
    mapping(uint256 => uint256) public wrongAtPlusOne; // 0 = never wrong
    mapping(uint256 => uint256) public evalGasCost;

    function setCircuit(uint256 id, address who, bool add, uint8 widthA, uint8 widthB, uint32 gates) external {
        owner[id] = who;
        info[id] = Info(add, widthA, widthB, gates);
        net[id] = abi.encodePacked("formula", id, add, widthA, widthB, gates);
    }

    function setWrongAt(uint256 id, uint256 c) external {
        wrongAtPlusOne[id] = c + 1;
    }

    function setEvalGasCost(uint256 id, uint256 cost) external {
        evalGasCost[id] = cost;
    }

    function setNetlist(uint256 id, bytes calldata n) external {
        net[id] = n;
    }

    function setGateCount(uint256 id, uint32 g) external {
        info[id].gateCount = g;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = owner[id];
        require(o != address(0), "ERC721NonexistentToken");
        return o;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Info memory i = info[id];
        uint32 nOut = i.add ? uint32(i.widthA) + 1 : 1;
        return (uint32(i.widthA) + i.widthB, nOut, 0, i.gateCount);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return net[id];
    }

    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory out) {
        uint256 cost = evalGasCost[id];
        if (cost > 0) {
            uint256 stopAt = gasleft() > cost ? gasleft() - cost : 0;
            while (gasleft() > stopAt) {}
        }
        Info memory i = info[id];
        uint256 x;
        for (uint256 k = 0; k < inputs.length; ++k) {
            x |= uint256(uint8(inputs[k])) << (8 * k);
        }
        uint256 a = x & ((uint256(1) << i.widthA) - 1);
        uint256 b = (x >> i.widthA) & ((uint256(1) << i.widthB) - 1);
        uint256 r = i.add ? a + b : (a >= b ? 1 : 0);
        if (wrongAtPlusOne[id] == x + 1) r ^= 1;
        uint256 nOut = i.add ? uint256(i.widthA) + 1 : 1;
        out = new bytes((nOut + 7) / 8);
        for (uint256 k = 0; k < out.length; ++k) {
            out[k] = bytes1(uint8(r >> (8 * k)));
        }
    }
}
