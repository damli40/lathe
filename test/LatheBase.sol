// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {BitLib} from "../src/BitLib.sol";
import {TableLib} from "../src/TableLib.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockProcessor, MockFactory} from "./mocks/MockProcessor.sol";

/// @notice Shared setup for the unit tests: mock token, mock factory, one mock processor, fee 1% (100 bps).
abstract contract LatheBase is Test {
    MockUSDT usdt;
    MockFactory factory;
    MockProcessor proc;
    LatheOrders lathe;

    address buyer = makeAddr("buyer");
    address builder = makeAddr("builder");
    address feeTo = makeAddr("feeTo");
    address stranger = makeAddr("stranger");

    uint16 constant FEE_BPS = 100;
    uint96 constant AMOUNT = 1_000_000_000; // 1,000 USDT at 6 decimals
    /// Gate count for fixtures that test the batched check path: big enough that even a 4-case order's
    /// cases x evalBudget is above INLINE_CHECK_MAX_GAS, so deliver does not check inline (FIX 4).
    uint32 constant BATCHED_GATES = 500;

    function setUp() public virtual {
        usdt = new MockUSDT();
        factory = new MockFactory();
        proc = new MockProcessor();
        factory.setCPU(address(proc), true);
        lathe = new LatheOrders(address(factory), address(usdt), feeTo, FEE_BPS);
        usdt.mint(buyer, 100 * uint256(AMOUNT));
        vm.prank(buyer);
        usdt.approve(address(lathe), type(uint256).max);
    }

    /// XOR: cases 0..3 -> 0,1,1,0, packed LSB first = 0b0110.
    function xorTable() internal pure returns (bytes memory) {
        return hex"06";
    }

    function createXor() internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), address(0), 0);
    }

    /// A 6-input, 1-output table: answer = parity of the case number (64 cases, 8 bytes).
    function parityTable() internal pure returns (bytes memory t) {
        t = new bytes(8);
        for (uint256 c = 0; c < 64; ++c) {
            uint256 p;
            for (uint256 b = 0; b < 6; ++b) {
                p ^= (c >> b) & 1;
            }
            if (p == 1) t[c / 8] = bytes1(uint8(t[c / 8]) | uint8(1 << (c % 8)));
        }
    }

    function createParity() internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createOrder(6, 1, parityTable(), AMOUNT, uint64(block.timestamp + 1 days), address(0), 0);
    }

    /// Register circuit `id` on the mock processor, owned by `who`, answering `table` exactly.
    function setCircuitFromTable(uint256 id, address who, uint8 nIn, uint8 nOut, bytes memory table, uint32 gates)
        internal
    {
        proc.setCircuit(id, who, nIn, nOut, 0, gates);
        uint256 cases = uint256(1) << nIn;
        bytes[] memory o = new bytes[](cases);
        for (uint256 c = 0; c < cases; ++c) {
            o[c] = BitLib.pack(TableLib.expected(table, c, nOut), nOut);
        }
        proc.setOuts(id, o);
    }
}
