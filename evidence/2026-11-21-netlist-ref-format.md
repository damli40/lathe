# Netlist and REF byte format, checked against live X Layer bytes (2026-11-21)

**VERDICT: GO.**
The netlist format and the REF encoding are fully documented, and the live X Layer bytes match the spec exactly (3 live circuits decoded by hand and rebuilt byte for byte by a throwaway Python encoder: 3 of 3 identical).
A contract can build the exact bytes of a "top" circuit made only of REFs plus wires, then compare `keccak256(netlist(topId))` to `keccak256(expectedBytes)`, with no parser needed on chain.
Two things are NOT done: no Solidity encoder was written or run (only a Python one), and the X Layer circuit implementation `0x977f...29B2` has no verified source, so its minting rules are shown by simulation, not by reading source (section 5).
The one trap that decides how you build it: the top circuit's outputs must be its last signals (section 1), and `netlist()` does not contain `nIn` or `nOut` (section 4).

Read-only throughout. Only `cast call`, `cast storage`, `cast code`, and `eth_call` simulations. Nothing was signed or sent. RPC `https://rpc.xlayer.tech` (chainId 196), one request at a time with pauses, plus batched `Multicall3` reads (`0xcA11bde05977b3631167028862bE2a173976CA11`) for the census. Date of every read: 2026-11-21 (UTC).

## Plain-language summary

A circuit is stored as a list of records. There are three kinds of record: a NAND gate (7 bytes), a LATCH memory bit (4 bytes), and a REF (31 bytes plus 3 bytes per input wire). A REF means "drop in another circuit here as a black box". There is no header and no length field; the length is the length of the bytes.

Every wire is a number. Number 0 is the constant 0, number 1 is the constant 1, then the circuit's inputs, then the outputs of each record in the order the records appear. A record can only read wires with a smaller number than the ones it creates (it can only look backwards). So the bytes are fixed once you fix three things: the order of the records, which circuit each REF points at, and which wire feeds each pin.

## Sources

- Spec: TAP-02 "Circuit Netlist Format and Evaluation Semantics", `https://github.com/TapeOutProtocol/TAPs/blob/main/TAPs/TAP-02.md` (raw: `https://raw.githubusercontent.com/TapeOutProtocol/TAPs/main/TAPs/TAP-02.md`, fetched 2026-11-21, header says status Draft, updated 2026-10-04). TAP-10 lists the X Layer contracts. No other TAP defines the netlist. The other TAPs (10 to 19, 21) do not contain a netlist or REF definition.
- Warning from the spec itself, quote: "Base (8453) and X Layer (196). TAP-10 lists different contracts on these chains ... This TAP has not compared them with the text, and has not read their source." So the spec was checked on BNB Smart Chain only. That is why everything below is also checked against live X Layer bytes.
- Result of that check: **no disagreement found** between the spec and the X Layer bytes or behaviour (record sizes, wire numbering, revert messages all match). The only difference found is `nextId()` (section 5, side finding), which is about the processor, not the netlist format.

### TAP-02 section 2, verbatim

> A circuit has `nIn` inputs and `nOut` outputs, `0 ≤ nIn ≤ 65,536` and `1 ≤ nOut ≤ 65,536`. `nIn` MAY be 0 (a circuit driven only by its state). Signals are numbered:
>
> | Index | Signal |
> |---|---|
> | 0 | constant 0 |
> | 1 | constant 1 |
> | 2 … 2 + nIn − 1 | the inputs, input `i` at index `2 + i` |
> | 2 + nIn onward | the outputs of the elements, in record order; each element appends the signals it produces |
>
> A netlist is a concatenation of records with no header, no padding and no terminator. `nIn` and `nOut` are not part of the netlist bytes; they are stored alongside it (§6). All multi-byte integers are big-endian. `u24` is a 3-byte unsigned integer, used for signal indices.
>
> | Opcode | Name | Record after the opcode byte | Record length | Signals produced |
> |---|---|---|---|---|
> | `0x00` | NAND | `a:u24 b:u24` | 7 bytes | 1: `NOT (a AND b)` |
> | `0x01` | LATCH | `d:u24` | 4 bytes | 1: the stored state bit (§4) |
> | `0x02` | REF | `cpu:20 bytes, id:u64, nIns:u8, nOuts:u8, ins:u24 × nIns` | 31 + 3·nIns bytes | nOuts: the outputs of circuit (`cpu`, `id`) |

Section 3 (well-formedness) adds: the last `nOut` signals are the outputs ("`2 + nIn + nOut ≤ S`. The outputs are therefore always signals produced by elements, never inputs or constants", and section 4 step 4: "`outputs` are the last `nOut` signals, `s[S − nOut] … s[S − 1]`, in index order").

## 1. The byte layout (confirmed on live bytes)

- Header: none. Not even a length. `nIn` and `nOut` are stored next to the bytes, not inside them.
- NAND = `00 | a (3 bytes) | b (3 bytes)` = 7 bytes. The 652-gate multiplier at 4,564 bytes is 652 x 7 = 4,564, so it has no LATCH and no REF. Confirmed.
- Endianness: big-endian, for the wire numbers (u24) and for the REF circuit id (u64).
- Wire numbering: 0 = constant 0, 1 = constant 1, input `i` = wire `2 + i`, then each record appends its output(s). A NAND adds 1 wire, a REF adds `nOuts` wires.
- Outputs: the circuit's outputs are its **last `nOut` wires**, in order. This matters a lot for building tops (section 4).
- State bits (only for LATCH, and for REFs to circuits that have LATCHes): each LATCH takes the next state bit, each REF takes a block of the sub-circuit's `nState` bits, in record order. Not needed for combinational pieces.
- Bit packing of `eval` input and output: least significant bit first within each byte, byte 0 holds bits 0 to 7 (TAP-02 section 5). Confirmed by the adder below (input bit 0 = lowest bit of byte 0).

### XOR decoded by hand

Circuit: processor `0x839bdD6fa7A66416A609A735e11DE5411B98574e` id 1. `circuitInfo(1)` = (nIn 2, nOut 1, nState 0, gates 4), read at block 76,478,992 on 2026-11-21 with `cast call <processor> 'circuitInfo(uint256)(uint32,uint32,uint32,uint32)' 1`.
`netlist(1)` (same block): `0x00000002000003000000020000040000000300000400000005000006` = 28 bytes = 4 records x 7.

Wires: 0 = const 0, 1 = const 1, 2 = input A, 3 = input B. The gates create wires 4, 5, 6, 7.

| Bytes (offset) | Hex | Meaning | Creates |
|---|---|---|---|
| 0 | `00` | opcode NAND | |
| 1 to 3 | `000002` | a = wire 2 (A) | |
| 4 to 6 | `000003` | b = wire 3 (B) | wire 4 = NAND(A,B) |
| 7 | `00` | NAND | |
| 8 to 10 | `000002` | a = wire 2 (A) | |
| 11 to 13 | `000004` | b = wire 4 | wire 5 = NAND(A, w4) |
| 14 | `00` | NAND | |
| 15 to 17 | `000003` | a = wire 3 (B) | |
| 18 to 20 | `000004` | b = wire 4 | wire 6 = NAND(B, w4) |
| 21 | `00` | NAND | |
| 22 to 24 | `000005` | a = wire 5 | |
| 25 to 27 | `000006` | b = wire 6 | wire 7 = NAND(w5, w6) |

Output = last 1 wire = wire 7. Truth table: A,B = 00: w4=1, w5=1, w6=1, w7=0. 01: w4=1, w5=1, w6=0, w7=1. 10: w4=1, w5=0, w6=1, w7=1. 11: w4=0, w5=1, w6=1, w7=0. That is XOR.
Chain check (block 76,479,935, `cast call ... 'eval(uint256,bytes)(bytes)' 1 <x> --block 76479935`): inputs `0x00,0x01,0x02,0x03` returned `0x00,0x01,0x01,0x00`. Matches.

The 3-input circuit on `0xCa6Fa40e0b548aBa9132F3f5050eE4C4c5eB7340` id 3 has the same shape: netlist `0x00000004000004000000020000050000000300000400000006000007` (28 bytes, 4 gates, `circuitInfo` = 3,1,0,4, block 76,478,992). Same 7-byte records.

## 2. The REF encoding (confirmed on live bytes)

A REF record is `02 | cpu (20 bytes) | id (8 bytes) | nIns (1 byte) | nOuts (1 byte) | nIns x wire (3 bytes each)`.
Length is 31 + 3 x nIns. Example with 2 inputs: 37 bytes.

- Which circuit: the processor address (20 raw bytes) plus the circuit id (u64). Both are in the record, so a REF can point to **another processor**. Confirmed live (below, `0x839b...` id 4 points at `0xf044...` id 102) and confirmed by simulation with inputs.
- Wiring: the `ins` list gives which existing wires feed the target's inputs 0, 1, 2 ... in order. The target's outputs become `nOuts` new consecutive wires, output 0 first. They are numbered right after whatever came before.
- `nIns` and `nOuts` must equal the target's `nIn` and `nOut` exactly, or minting reverts `REF: pin mismatch`. Because they are one byte each, only circuits with 255 inputs or fewer and 255 outputs or fewer can be referenced.
- Each `ins` wire must be smaller than the first wire the REF creates (look backwards only). Constants 0 and 1 are allowed as inputs. Confirmed: `REF: future signal` reverts otherwise.
- REF targets can themselves have REFs: confirmed live. Processor `0xb00e17789f905234f1890c22e6c01015c10d2f54` id 11 references ids 8, 9, 10, which themselves contain REFs (28 such nested links in the census below). The spec says the minting step has no depth limit (a 16-level limit exists only for the Proof-of-Design miner). I did not test a deep chain.
- Limits that exist: wires total at most 2^24, total state bits at most 2^24, total gate count at most 2^32 - 1, REF arity at most 255. There is **no maximum number of REFs** and no netlist-size cap other than transaction gas. Real limits are in running it: Lathe's earlier measurement is about 40,000 gas per REF to a 4-gate piece (`2026-11-20-eval-gas-budget.md`, measured on a fork, not live circuits).
- Gate count: the top circuit's `circuitInfo` gate count **includes** gates inside referenced circuits. Confirmed live: id 5 below reports 6 = 3 + 1 + 2, the adder reports 42 = 4 x 9 + 6, and `0x839b` id 4 reports 10 (all from the single REF).

### Census of live REF use (so you know how common this is)

Scan on 2026-11-21 (about 08:05 to 08:20 UTC, blocks about 76,479,000 to 76,480,000): all 438 processors listed from the factory with `cpuAt`, then `netlist(id)` for ids 1 to `nextId()-1` on every processor, 11,400 circuits read through Multicall3, each parsed with the record rules above (no parse failures). Caveat: on X Layer `nextId()` returns the highest existing id (section 5, side finding), so the newest circuit of each processor was not scanned. The result is a lower bound.
- 288 circuits contain at least one REF.
- 229 of them are 31-byte netlists: a single REF with 0 inputs to a 10-gate latched circuit (228 point at `0xf044d395c91e77459e6b2155015e14f0dd9b349f` id 102, one at `0xe0ef4fffd869cbd24b2f83e6d2d83109937e05ff` id 22). Almost all on processor `0x839b...`. These are cross-processor REFs.
- 59 are richer: REFs with 2 to 240 inputs, 1 to 162 outputs, mixed with NAND records, nested REFs.
- Multi-output REFs are live (for example 3 in / 2 out, 4 in / 4 out, 9 in / 5 out).

## 3. One live REF circuit decoded by hand

**Circuit A (the main worked example).** Processor `0xb04eb79d1a5eecaabaaff7b77d7c27578ee693ff` (name "Cerebr"), id 5. Read at block **76,479,265**, 2026-11-21.
`cast call <proc> 'circuitInfo(uint256)(uint32,uint32,uint32,uint32)' 5` = nIn 2, nOut 1, nState 0, gateCount 6.
`netlist(5)` = 111 bytes = 3 records x 37 bytes:

```
02b04eb79d1a5eecaabaaff7b77d7c27578ee693ff0000000000000002020100000200000302b04eb79d1a5eecaabaaff7b77d7c27578ee693ff0000000000000003020100000200000302b04eb79d1a5eecaabaaff7b77d7c27578ee693ff00000000000000010201000004000005
```

Wires 0,1 constants; 2 = input A; 3 = input B. Three REFs, each 37 bytes:

| Bytes | Hex | Field |
|---|---|---|
| 0 | `02` | opcode REF |
| 1 to 20 | `b04eb79d1a5eecaabaaff7b77d7c27578ee693ff` | cpu (same processor) |
| 21 to 28 | `0000000000000002` | circuit id = 2 |
| 29 | `02` | nIns = 2 |
| 30 | `01` | nOuts = 1 |
| 31 to 33 | `000002` | in0 = wire 2 (A) |
| 34 to 36 | `000003` | in1 = wire 3 (B) -> creates wire 4 |
| 37 to 73 | `02` + same cpu + `0000000000000003` + `02 01` + `000002 000003` | REF to id 3, ins A,B -> creates wire 5 |
| 74 to 110 | `02` + same cpu + `0000000000000001` + `02 01` + `000004 000005` | REF to id 1, ins w4,w5 -> creates wire 6 |

The pieces it references (all on the same processor, read at the same block 76,479,265):
- id 3: `00 000003 000002` = one NAND(B,A). info 2,1,0,1. So wire 5 = NAND(A,B).
- id 2: `00000002000002 00000003000003 00000004000005`: NAND(A,A)=NOT A, NAND(B,B)=NOT B, then NAND of those = A OR B. info 2,1,0,3. So wire 4 = A OR B.
- id 1: `00000003000002 00000004000004`: NAND(B,A), then NAND of that with itself = A AND B. info 2,1,0,2. So wire 6 = AND(w4, w5).

Output = last wire = wire 6 = (A OR B) AND NAND(A,B) = XOR. Gate count 3 + 1 + 2 = 6 matches `circuitInfo`.
Chain check, `cast call <proc> 'eval(uint256,bytes)(bytes)' 5 <x> --block 76479265`: inputs `0x00,0x01,0x02,0x03` returned `0x00,0x01,0x01,0x00`. Matches XOR as predicted.
Rebuild test: a Python encoder given only (processor, ids, wires) produced these 111 bytes exactly (`cast keccak` of them = `0xaf654440443a6fbd0d5d22226905e7468312fe2d7163ecc82edf8501f591dbc3`, computed locally from the bytes read on chain).

**Circuit B (cross-processor, no inputs).** Processor `0x839bdD6fa7A66416A609A735e11DE5411B98574e` id 4. `netlist(4)` = `0x02f044d395c91e77459e6b2155015e14f0dd9b349f00000000000000660001` (31 bytes): `02` REF, cpu `f044d395c91e77459e6b2155015e14f0dd9b349f` (a different processor), id `0000000000000066` = 102, nIns `00`, nOuts `01`. It has no `ins`. Target `0xf044...` id 102: info (0,1,2,10), netlist `0x0100000701000009000000020000020000000300000300000004000005000000060000060000000200000500000008000008000000070000070000000a00000a` (a latched circuit: two LATCH records and 8 NANDs). `circuitInfo(4)` on `0x839b` = (0,1,2,10): the 10 gates and 2 state bits of the target are counted in the top. Read on 2026-11-21 between blocks 76,479,019 and 76,479,265 (exact block per call not recorded; I can re-read at a pinned block if needed). This one is not combinational, so I did not `eval` it.

**Circuit C (multi-output REFs, wires that matter).** Processor `0x99081e1d0ce916cd5b2c53e769dfc3b000bfe9a4` id 11, read at block **76,479,935**: `circuitInfo` = (9 in, 5 out, 0 state, 42 gates), netlist 202 bytes:

```
0299081e1d0ce916cd5b2c53e769dfc3b000bfe9a4000000000000000a030200000200000600000a
0299081e1d0ce916cd5b2c53e769dfc3b000bfe9a4000000000000000a030200000300000700000c
0299081e1d0ce916cd5b2c53e769dfc3b000bfe9a4000000000000000a030200000400000800000e
0000000b00000b 0000000d00000d 0000000f00000f 00000011000011 00000012000012 00000013000013
0299081e1d0ce916cd5b2c53e769dfc3b000bfe9a4000000000000000a0302000005000009000010
```
(line breaks added by me; the real bytes have none.) Decoded with my decoder: REF id 10 (a 9-gate full adder, 3 in / 2 out), ins [2,6,10], creates wires 11,12; REF id 10, ins [3,7,12], creates 13,14; REF id 10, ins [4,8,14], creates 15,16; six NANDs on wires 11,13,15 then twice again (NAND(x,x) then NAND(that,that) = a copy of x), creating wires 17 to 22; final REF id 10, ins [5,9,16], creates 23,24. Total wires 25. Outputs = the last 5 wires = 20,21,22,23,24 = the 4 sum bits and the carry. It is a 4-bit adder: inputs are a (bits 0 to 3), b (bits 4 to 7), carry-in (bit 8).
Why the six extra NANDs: the sum bits come out of the first three adders as wires 11,13,15, but the circuit's outputs must be the *last* 5 wires. So the builder copies each sum bit to the end with two NANDs (a NOT of a NOT). **The format forces this**: you cannot choose which wires are outputs.
Chain check (`eval(11, x)` at block 76,479,935), input shown as bits then bytes, predicted by my decoder+simulator vs chain: 000000000 -> 0x00 vs 0x00; 000000001 (`0100`) -> 0x01 vs 0x01; 111111111 (`ff01`) -> 0x1f vs 0x1f; 011110000 (`f000`) -> 0x0f vs 0x0f; 101010101 (`5501`) -> 0x0b vs 0x0b; 010101010 (`aa00`) -> 0x14 vs 0x14; 100100011 (`2301`) -> 0x06 vs 0x06. 7 of 7 identical. Rebuild test: Python encoder reproduced the 202 bytes exactly.

## 4. Is the encoding canonical?

**Short answer: for a fixed ordered recipe there is exactly one byte string, so a hash comparison works with no parser. But "the same wiring" has many valid encodings, so the recipe must fix the order.**

Where the freedom is (tested by simulated `tapeout`, section 5):
1. Record order. Any order that only looks backwards is accepted. Two orders of independent REFs make different bytes and different circuits that compute the same thing.
2. Wire numbers follow from the order, so they add no freedom of their own. For a given order, wire numbers are forced.
3. Dangling wires: a REF whose output nobody uses is accepted (a REF-only top with an unused extra REF is well-formed). So extra pieces are allowed.
4. Output wires: forced to be the last `nOut` wires, so which pieces come last is part of the recipe. Copy NANDs (two per output, as in circuit C) are one way to fix it; they cost 2 NANDs per output and the minter needs transistor tokens for top-level NANDs.
5. Which circuit: two different ids with the same function make different bytes.
6. No optional fields, no padding, no length field. Address case is irrelevant (20 raw bytes).
7. `nIn` and `nOut` are NOT in the bytes. Simulated `tapeout` accepted the identical 37-byte netlist (one REF to id 1, ins 2,3) with `nIn` = 2 and `nIn` = 3 (both returned an id). So `keccak256(netlist(id))` alone does not prove the interface. **Also check `circuitInfo(topId)` returns the expected nIn, nOut** (and `nState == 0`).
8. Nothing stops the same bytes being minted many times (no dedup seen in simulation), so the bytes prove content, not who made it.

**Simplest fixed convention for a builder:**
- Pieces in the exact order of the `circuitIds` array, one REF record each, no NAND or LATCH records at all.
- Each piece's input wires are given explicitly in the `wires` array, in input-pin order.
- Wire number of piece k's output j = `2 + nIn + (sum of nOuts of pieces 0..k-1) + j`. Wire number of top input i = `2 + i`. Constants 0 and 1 are wires 0 and 1.
- Top outputs must be the outputs of the last pieces, in order (last `nOut` wires). If the design does not end that way, the builder reorders the pieces. No buffers, so no transistor tokens are needed.
- Same processor address bytes as given, no normalisation.
Given that recipe, the encoder is a pure function and the hash is a complete check.

## 5. What minting requires (read-only; nothing minted)

Sources: TAP-02 section 6 (BNB version), then the live X Layer processor `0xb04eb79d1a5eecaabaaff7b77d7c27578ee693ff` by `eth_call` simulation. Source for the X Layer implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` is **not confirmed**: not verified on Sourcify (`https://sourcify.dev/server/v2/contract/196/0x977f...` returned no match), Routescan says chain not supported, Blockscout returned 404, the OKX explorer needs a browser. What I did instead: `cast code 0x977f...` (25,127 hex characters, selectors `0x7bd3ac1d` tapeout, `0x3fc4be56` netlist, `0x934d06ea` eval, `0xe8281a1a` step, `0x084d60f1` circuitInfo all present) and the simulations below.
The beacon is `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` (processor 0xb04e... beacon slot `0xa3f0...3d50` = that address, `cast storage`), whose `implementation()` = `0x977f...29B2` (blocks 76,479,0xx to 76,479,265). Factory `isSealed()` = false at block 76,479,019 (`0x1f09...0761`, 438 processors then; `cpuCount()` = 438). So the implementation could be swapped by the factory owner. A verifier should record `implementation()` at the block it reads.

How to call: `tapeout(bytes netlist, uint32 nIn, uint32 nOut) payable returns (uint256 id)`, selector `0x7bd3ac1d`.

Results of `cast call <proc> 'tapeout(bytes,uint32,uint32)(uint256)' ... --from 0x...dEaD --override-balance ...` (a simulation: no transaction, no signature; blocks 76,479,482 to 76,479,559; the caller `0x000...dEaD` held no circuits and no transistor tokens):

| What I simulated | Result |
|---|---|
| One REF (id 1, ins 2,3) with value = 0.0013 OKB | returns id 39. **A REF-only netlist mints with zero tokens, no ownership of the pieces.** |
| Same, value 0 | `tapeout fee` |
| Same, value 0.0013 OKB + 1 wei | `tapeout fee` (fee must match exactly) |
| REF to id 99 / 0x63 that does not exist | `no circuit` (a REF cannot point at a circuit that does not exist yet) |
| REF with nIns=1 where target takes 2 | `REF: pin mismatch` |
| REF with cpu `0x...dEaD` (not a processor) | `REF: target not a registered CPU` |
| REF input wire not yet created | `REF: future signal` |
| REF to `0x839b...` id 1 (XOR) from processor `0xb04e...` with 2 inputs (cross-processor, with inputs) | returns id 39, accepted |
| REF to `0xf044...` id 102 with 0 inputs (cross-processor) | accepted |
| REF to id 5 (itself a REF circuit) | accepted (nested) |
| REF whose output count is less than `nOut` (nOut=2, one REF with 1 output) | `too few signals for outputs` |
| Unknown opcode `0x03` | `bad opcode` |
| Well-formed netlist with a top-level NAND appended | reverts at the token burn with the ERC-1155 insufficient balance error `0x03dee4c5` (balance 0, needed 1). So the order is: fee, then well-formedness, then burn, as TAP-02 says. |
| Constants (wires 0,1) as REF inputs, `nIn` = 0 | accepted |

Answers to your questions:
- **Function:** `tapeout`, on the processor that will hold the new circuit (the top can live on a different processor than its pieces).
- **Who can call it:** anyone, no owner check seen on this processor. This is one processor (0xb04e). Other processors share the same implementation through the beacon, but I did not simulate on others. The per-processor transistor token mint price is set by each processor's creator (not measured).
- **Fee:** exact `TAPEOUT_FEE` in native OKB. Read from earlier note: 0.0013 OKB on pre-Nov-8 processors; I re-read `TAPEOUT_FEE()` on `0xb04e...` = 1,300,000,000,000,000 wei (0.0013 OKB) at block 76,479,482 on 2026-11-21. The fee is in the implementation, not the spec.
- **REF validation:** processor registered in the factory, target exists, pin counts match, wires look backwards, size limits. The minter does **not** need to own, or hold tokens for, the referenced circuits. A REF cannot point at a circuit that does not exist yet.
- **Burn:** one transistor token per top-level NAND or LATCH; gates reached through REF burn nothing. A REF-only top needs 0 tokens.
- **Side finding:** on X Layer `nextId()` returns the **highest existing id**, not "the id the next circuit gets" as TAP-02 says. Processor `0xb04e...`: `nextId()` = 38 at block 76,480,066; id 38 exists (4 in / 1 out / 16 gates), id 39 reverts `no circuit`, and the simulated mint returns 39. Anything in Lathe that loops `1 ..< nextId()` skips the newest circuit; use `1 ..= nextId()`.
- Implementation caveat from the spec: "the circuit implementation behind the beacon" is a different build here than the BSC one the spec's source reading covered. I did not diff them. The simulations above show the X Layer behaviour matches the spec on every case I tried.

## 6. Sketch: `encodeRefTop`

Idea: build the bytes in memory, then compare hashes. Inputs are the recipe from section 4.

```solidity
struct Wire { uint24 src; }   // a wire number; encoder trusts the caller's numbering, see note

function encodeRefTop(
    address[] memory processors,   // one per piece, in record order
    uint256[] memory circuitIds,   // one per piece
    uint8[] memory nOuts,          // how many wires each piece makes (needed to number wires)
    Wire[][] memory wires,         // wires[k] = input wires of piece k, in pin order
    uint8 nIn, uint8 nOut
) public pure returns (bytes memory out) {
    // require equal lengths; require nIn/nOut fit the rules (nOut >= 1)
    uint256 next = 2 + nIn;                      // first wire the first piece creates
    for (uint256 k; k < processors.length; ++k) {
        for (uint256 j; j < wires[k].length; ++j)
            require(wires[k][j].src < next, "future wire");   // look backwards only
        out = bytes.concat(out,
            bytes1(0x02), bytes20(processors[k]), bytes8(uint64(circuitIds[k])),
            bytes1(uint8(wires[k].length)), bytes1(nOuts[k]));
        for (uint256 j; j < wires[k].length; ++j)
            out = bytes.concat(out, bytes3(wires[k][j].src));
        next += nOuts[k];
    }
    require(next - (2 + nIn) >= nOut, "too few signals for outputs");
}
// caller: require(keccak256(IProcessor(topProc).netlist(topId)) == keccak256(encodeRefTop(...)));
//         require(circuitInfo(topId) returns nIn, nOut, nState 0 as expected);
```

Notes on the sketch:
- `nIn` and `nOut` are 16 bit in the spec (up to 65,536), shown here as `uint8` only for brevity; use `uint32` and only use them for numbering and the last check, they are not written to the bytes.
- It needs no external call: if `nOuts[k]` is wrong the bytes differ and the hash fails, so the comparison fails closed. (The expected circuit was validated when it was minted, which checked every pin count.)
- If you want the top to be Lathe's own `Wire{fromPiece, fromPin}` instead of raw numbers, add a small lookup: wire number = `2 + nIn + prefixOuts[fromPiece] + fromPin`, or `2 + i` for inputs. About 15 more lines.
- Size: roughly 40 to 60 lines of Solidity, roughly 1.5 to 3 KB of runtime bytecode (a judgement, not measured, no compile was run). Gas to build the bytes is small next to reading `netlist` (a 1.4 KB netlist is read through SSTORE2 chunks).
- Do not use `bytes.concat` in a loop for tops with hundreds of REFs: it re-copies each time (quadratic). Allocate `new bytes(total)` up front (total = 31 x pieces + 3 x total pin wires) and write with `mstore`, or accept the quadratic cost for small tops. Not measured.
- Cost of reading and hashing: `netlist(topId)` returns the whole bytes; 111 bytes for circuit A, 202 bytes for the adder.

## Not confirmed, and what I tried

- Solidity encoder: not written or run. Only a Python encoder (3 of 3 live netlists rebuilt byte for byte). The sketch above is untested. No Solidity compile was run (scratch folder only, nothing in the repo).
- X Layer implementation source: not available (Sourcify, Routescan, Blockscout tried). Behaviour shown by simulation on one processor only.
- Depth limits: I did not simulate a deep REF chain or measure gas on a live REF-only circuit. Gas per REF comes from the earlier fork measurement.
- Cross-processor REF with inputs is accepted in simulation but no live circuit does it; the live cross-processor REFs have 0 inputs.
- Whether a top on one processor can reference pieces of every other processor: tested for 3 pairs only (`0xb04e` to `0x839b`, `0x839b` to `0xf044`, same-processor).
- The census is a lower bound: it skipped each processor's newest circuit (see section 5, side finding).
- The factory is not sealed (`isSealed()` false at block 76,479,019), so a beacon upgrade could change evaluation after you rely on it.
- I did not eval Circuit B (latched). The REF state-layout rules in TAP-02 section 4 are untested by me.

## Commands, for reproduction (replace `<proc>`)

- Block: `cast block-number --rpc-url https://rpc.xlayer.tech`
- `cast call <proc> 'circuitInfo(uint256)(uint32,uint32,uint32,uint32)' <id> --rpc-url https://rpc.xlayer.tech`
- `cast call <proc> 'netlist(uint256)(bytes)' <id> --rpc-url https://rpc.xlayer.tech`
- `cast call <proc> 'eval(uint256,bytes)(bytes)' <id> <hex> --block <n> --rpc-url https://rpc.xlayer.tech`
- Simulated mint: `cast call <proc> 'tapeout(bytes,uint32,uint32)(uint256)' <netlistHex> <nIn> <nOut> --value 1300000000000000 --from 0x000000000000000000000000000000000000dEaD --override-balance 0x000000000000000000000000000000000000dEaD:1000000000000000000 --rpc-url https://rpc.xlayer.tech`
- Scratch scripts (decoder, simulator, encoder, scanner, raw scan output) are in `/private/tmp/claude-501/-Users-Admin-Documents-Knowledge-base/61def479-520a-45a1-b376-0465e6c35933/scratchpad/refspike/` (`dec.py`, `enc.py`, `t11.py`, `scan2.py`, `refs.jsonl`).
