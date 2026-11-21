// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";

interface IERC20Ref {
    function approve(address, uint256) external returns (bool);
}

interface ITapeOutRef {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @dev One eval with all the gas there is, measured inside this contract (so no transaction overhead), and the
/// same eval twice in one call: the second is the warm cost (every account and storage slot already touched).
contract RefGasMeter {
    function once(address p, uint256 id, bytes calldata x) external view returns (uint256 used, bytes memory out) {
        uint256 g0 = gasleft();
        out = IProcessor(p).eval(id, x);
        used = g0 - gasleft();
    }

    function twice(address p, uint256 id, bytes calldata x) external view returns (uint256 first, uint256 second) {
        uint256 g0 = gasleft();
        IProcessor(p).eval(id, x);
        uint256 g1 = gasleft();
        IProcessor(p).eval(id, x);
        first = g0 - g1;
        second = g1 - gasleft();
    }
}

/// @notice Gas per REF (reference) record on real TapeOut (X Layer mainnet fork pinned at block 76,480,000; every
/// circuit here is minted on the local fork with tapeout, nothing is sent to X Layer).
/// Circuits: chain(T, k) = k REFs in a row to a 2-input, 1-output part T: r0 = T(a, b), r(j) = T(a, r(j-1)); its
/// output is the last answer. Parts on processor 0xb04e...93ff: NAND id 3 (1 gate), AND id 1 (2 gates), OR id 2 (3 gates); on
/// 0x839b...574e: XOR id 1 (4 gates). Nested parts: N1 = one REF to NAND, N2 = one REF to N1 (each still 1 gate,
/// but one or two extra REFs deep).
/// For each circuit: the gate count TapeOut reports, LatheOrders.evalBudget (what one case gets), one eval's gas
/// (cold: first touch in its own transaction when run with --isolate) and the warm gas (the same eval again in the
/// same call), and whether a real V0 delivery of it passes the case check (deliver checks 4 cases inline).
/// Evidence: evidence/2026-11-21-ref-heavy-circuit-budget.md and evidence/2026-11-21-top-run-gas.md.
/// Run (cold figures): forge test --match-path 'test/fork/RefGas.fork.t.sol' --isolate -vv
/// Without --isolate the tests still pass, but every figure is warm (the circuits were minted in the same transaction).
contract RefGasForkTest is Test {
    uint256 constant FORK_BLOCK = 76_480_000;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant C = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF; // AND 1, OR 2, NAND 3, XOR top 5
    address constant X = 0x839bdD6fa7A66416A609A735e11DE5411B98574e; // XOR 1
    uint96 constant AMOUNT = 10_000_000;
    uint8 constant F_NAND = 0;
    uint8 constant F_AND = 1;
    uint8 constant F_XOR = 2;
    uint8 constant F_OR = 3;

    LatheOrders lathe;
    RefGasMeter meter;
    address buyer = makeAddr("buyer");
    address bld = makeAddr("bld");
    uint256 n1; // one REF to NAND
    uint256 n2; // one REF to n1

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        meter = new RefGasMeter();
        deal(USDT0, buyer, 1000 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20Ref(USDT0).approve(address(lathe), type(uint256).max);
        vm.deal(bld, 100 ether);
        n1 = _mint(C, _ref(C, 3, 2, 3), 2, 1);
        n2 = _mint(C, _ref(C, n1, 2, 3), 2, 1);
    }

    function _u24(uint256 x) internal pure returns (bytes3) {
        return bytes3(uint24(x));
    }

    function _ref(address cpu, uint256 id, uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"02", cpu, uint64(id), uint8(2), uint8(1), _u24(a), _u24(b));
    }

    function _mint(address p, bytes memory nl, uint32 nIn, uint32 nOut) internal returns (uint256 id) {
        uint256 fee = ITapeOutRef(p).TAPEOUT_FEE();
        vm.prank(bld);
        id = ITapeOutRef(p).tapeout{value: fee}(nl, nIn, nOut);
    }

    /// k REFs in a row to (cpu, id), minted on C.
    function _chain(address cpu, uint256 id, uint256 k) internal returns (uint256) {
        bytes memory nl;
        for (uint256 j = 0; j < k; ++j) {
            nl = abi.encodePacked(nl, _ref(cpu, id, 2, j == 0 ? 3 : 4 + j - 1));
        }
        return _mint(C, nl, 2, 1);
    }

    function _f(uint8 fn, uint256 a, uint256 b) internal pure returns (uint256) {
        if (fn == F_NAND) return 1 - (a & b);
        if (fn == F_AND) return a & b;
        if (fn == F_OR) return a | b;
        return a ^ b;
    }

    /// The chain's truth table from the part's rule (not from eval): 4 cases, 1 output.
    function _table(uint8 fn, uint256 k) internal pure returns (bytes memory t) {
        uint8 v;
        for (uint256 c = 0; c < 4; ++c) {
            uint256 a = c & 1;
            uint256 r = _f(fn, a, c >> 1);
            for (uint256 j = 1; j < k; ++j) {
                r = _f(fn, a, r);
            }
            v |= uint8(r << c);
        }
        t = abi.encodePacked(v);
    }

    struct Row {
        uint256 k;
        uint32 gates;
        uint256 budget;
        uint256 cold;
        uint256 warm;
        bool passes;
    }

    /// Measure chain(target, k): gas, budget, and the real case-check verdict through deliver.
    function _row(address cpu, uint256 id, uint8 fn, uint256 k) internal returns (Row memory r) {
        uint256 cid = _chain(cpu, id, k);
        r.k = k;
        (,,, r.gates) = IProcessor(C).circuitInfo(cid);
        r.budget = lathe.evalBudget(r.gates);
        // The verdict first, so its first case is the circuit's first eval (cold under --isolate).
        vm.prank(buyer);
        uint256 order = lathe.createOrder(2, 1, _table(fn, k), AMOUNT, uint64(block.timestamp + 1 days), bld, 0);
        vm.prank(bld);
        try lathe.deliver{gas: 30_000_000}(order, C, cid) {
            r.passes = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), LatheOrders.WrongAnswer.selector, "deliver refused for another reason");
        }
        bytes memory out;
        (r.cold, out) = meter.once(C, cid, hex"03");
        assertEq(out, abi.encodePacked((uint8(_table(fn, k)[0]) >> 3) & 1), "eval vs rule");
        (, r.warm) = meter.twice(C, cid, hex"03");
        console.log(
            string.concat(
                "k=", vm.toString(k), " gates=", vm.toString(r.gates), " budget=", vm.toString(r.budget),
                " eval=", vm.toString(r.cold), " warm=", vm.toString(r.warm), r.passes ? " PASS" : " REJECTED"
            )
        );
    }

    function _sweep(string memory name, address cpu, uint256 id, uint8 fn, uint256[] memory ks)
        internal
        returns (uint256 largestPass, uint256 smallestReject)
    {
        console.log(name);
        for (uint256 i = 0; i < ks.length; ++i) {
            Row memory r = _row(cpu, id, fn, ks[i]);
            if (r.passes) {
                largestPass = r.k;
            } else if (smallestReject == 0) {
                smallestReject = r.k;
            }
        }
        console.log("  largest k that passes", largestPass, "smallest k rejected", smallestReject);
    }

    function _ks() internal pure returns (uint256[] memory ks) {
        ks = new uint256[](12);
        uint256[12] memory v = [uint256(1), 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 24];
        for (uint256 i = 0; i < 12; ++i) {
            ks[i] = v[i];
        }
    }

    /// REFs to the 1-gate NAND: the cheapest gate count per REF, so the tightest honest case.
    function test_fork_refChain_nand() public {
        (uint256 pass, uint256 rej) = _sweep("chain of REFs to NAND (1 gate)", C, 3, F_NAND, _ks());
        assertGe(pass, 1, "even one REF to NAND is rejected");
        assertGt(rej, 0, "no REF-to-NAND chain was rejected up to 24 REFs");
    }

    function test_fork_refChain_and() public {
        uint256[] memory ks = _ks();
        ks[8] = 13; // 10, 12 -> 13, 14 to find the line between 12 (passes) and 16 (rejected)
        ks[9] = 14;
        (uint256 pass, uint256 rej) = _sweep("chain of REFs to AND (2 gates)", C, 1, F_AND, ks);
        assertGe(pass, 4, "a short chain of REFs to AND is rejected");
        assertGt(rej, 0, "no REF-to-AND chain was rejected up to 24 REFs");
    }

    /// REFs to the 3-gate OR: 45,000 of budget per REF, above what one costs.
    function test_fork_refChain_or() public {
        (, uint256 rej) = _sweep("chain of REFs to OR (3 gates)", C, 2, F_OR, _ks());
        assertEq(rej, 0, "an honest chain of REFs to the 3-gate OR was rejected");
    }

    function test_fork_refChain_xor() public {
        (, uint256 rej) = _sweep("chain of REFs to XOR (4 gates)", X, 1, F_XOR, _ks());
        assertEq(rej, 0, "an honest chain of REFs to the 4-gate XOR was rejected");
    }

    function test_fork_refChain_nested1() public {
        _sweep("chain of REFs to N1 = REF to NAND (1 gate, 2 REFs deep)", C, n1, F_NAND, _ks());
    }

    function test_fork_refChain_nested2() public {
        _sweep("chain of REFs to N2 = REF to REF to NAND (1 gate, 3 REFs deep)", C, n2, F_NAND, _ks());
    }

    /// The parts on their own, and the live REF-only XOR (C id 5: REFs to OR, NAND, AND; 6 gates), for comparison
    /// with eth_estimateGas on an anvil fork (evidence/2026-11-21-top-run-gas.md). "first" is one eval in a call of
    /// its own, "again" the same eval repeated inside one call.
    function test_fork_partsAlone() public view {
        _part("NAND C id 3", C, 3, hex"03");
        _part("AND C id 1", C, 1, hex"03");
        _part("OR C id 2", C, 2, hex"03");
        _part("XOR X id 1", X, 1, hex"01");
        (uint256 used, bytes memory out) = _part("live XOR top C id 5", C, 5, hex"01");
        assertEq(out, hex"01");
        assertLe(used, lathe.evalBudget(6) + lathe.EVAL_GAS_PER_REF() * 3, "live top above its run budget");
    }

    function _part(string memory name, address p, uint256 id, bytes memory x)
        internal
        view
        returns (uint256 used, bytes memory out)
    {
        (used, out) = meter.once(p, id, x);
        (uint256 a, uint256 b) = meter.twice(p, id, x);
        (,,, uint32 gates) = IProcessor(p).circuitInfo(id);
        console.log(string.concat(name, ": gates ", vm.toString(gates), " budget ", vm.toString(lathe.evalBudget(gates))));
        console.log(string.concat("  first ", vm.toString(used), " twice: ", vm.toString(a), " then ", vm.toString(b)));
    }
}
