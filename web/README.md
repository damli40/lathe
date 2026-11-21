# Lathe web page

One static page: the pitch on top, the working order tool below, in English and Simplified Chinese.
Plain HTML, CSS and ES modules. No framework, no build step, nothing to install.

## Run it

Serve this folder with any static server, for example from the repo root:

```sh
python3 -m http.server -d web 8080   # then open http://127.0.0.1:8080/
```

Opening `index.html` as a file does not work: ES modules need http.

## Files

| File | What it does |
|---|---|
| `index.html` | Markup only. Every visible string is filled in from `i18n.js`. Holds the Content-Security-Policy. |
| `styles.css` | All styles. Colour tokens for dark and light; the corner and accent rules are at the top. |
| `app.js` | Language, theme, the hero figure, and the order tool (create, look up, deliver, check, refund). |
| `i18n.js` | The merged string dictionary: `pitch` from `i18n.pitch.js` plus the tool strings, EN and ZH. |
| `i18n.pitch.js` | Pitch copy (owned by the page owner, not edited here). |
| `config.js` | Network settings. Mainnet goes live by filling in one address: `NETWORKS.mainnet.lathe`. |
| `table.js` | Truth-table encoder and decoder, the same rule as `src/TableLib.sol`. Pure functions. |
| `gas.js` | Gas limits, inline-check rule, refund rules, amount parsing. Pure functions. |
| `pieces.js` | Pieced orders: each piece's expected answer and the joined rule, the same layout as `src/FormulaLib.sol` and `createPiecedOrder`. Pure functions, BigInt. |
| `abi.json` | `LatheOrders` ABI, extracted from `out/LatheOrders.sol/LatheOrders.json`. |
| `logo.svg` | Copy of `assets/logo.svg`; shown large in the hero when the figure is missing. |
| `figure.js`, `figure.css` | The hero drawing, built separately. Loaded only if present; the page works without them. |

Libraries load from CDNs, pinned: viem `2.21.0` from esm.sh, Geist and Geist Mono `5.2.5` from jsDelivr (`@fontsource`).

## How the tool behaves

- Reads go through the public RPC, so the order view and the create form work with no wallet.
  Testnet reads may run in parallel. On mainnet (its RPC returns 403 under parallel load) every request the page
  makes, including receipt polling, goes through one queue, so at most one is in flight at a time
  (`parallelReads: false` in `config.js`; `web/test/fixround.mjs` measures this through a proxy).
- The contract's constants (gas budget, inline limit, grace period, token, fee rate) are read from the contract,
  then cached in localStorage per chain id and contract address. A cached entry with a wrong type or an
  out-of-range value is thrown away and read again. The token's decimals are read again before any amount is sent.
  Nothing breaks if storage is blocked.
- The fee is shown where it matters: under the amount and on the order view ("The builder receives ... after the
  1% fee"). With a 0 fee nothing extra is shown.
- `deliver` and `check` are sent with an explicit gas limit: each case must hold
  `evalBudget * 64/63 + GAS_RESERVE` before the circuit runs, so a wallet's estimate is too low. The page also
  runs the call first (`eth_call`) and sends nothing if the contract would refuse, for example `WrongAnswer(3)`,
  which it shows as a sentence and a highlighted row.
- Before a delivery the page tests every case on its own: one `eth_estimateGas` per case, straight to the
  processor's `eval` (`step` for a memory order), each a fresh simulated transaction, so the circuits it calls are
  read cold, as for the first case of a check transaction. Estimate minus the call's base cost = what that case
  needs (`G.needFromEstimate`). Then `G.planCaseGas`: every case fits the standard budget with a 10% margin ->
  deliver as before; some case needs more -> propose `worst x 64/63 x 1.1` rounded up to 10,000, say what it means
  for the number of check transactions, and deliver with `deliver(orderId, processor, circuitId, caseGas)`; even
  100,000,000 is not enough -> say so and keep the deliver button off. A case that does not finish under 48M (then
  under about 103M, which a public node cuts to 50M again) or fails is listed as "could not test", never as fitting.
  On a contract without `caseGasOf` the page says the circuit may be rejected and delivers with the formula.
  Check, run and the crank read the stored figure (`caseGasOf`, `pieceCaseGasOf`) for their gas limits.
- The create form warns, without blocking, when the deadline is more than 90 days away: an order cannot be
  cancelled before its deadline.
- Both public X Layer RPCs run `eth_call` with at most 50,000,000 gas, whatever the call asks for. The page keeps
  every simulation under 48M: `deliver` always fits (at most about 35M inline); a `check` simulation runs only as
  many cases as fit, and when not even one case fits (circuits above 2,995 gates) the check is sent without a test
  run, which the check box says. A check that fails on chain only costs its gas; it cannot move money.
- A transaction that is mined but fails is reported as a failure, never as progress. If the hash is known but the
  receipt cannot be read, the page says so and names the hash; the create button stays locked until the receipt
  turns up.
- Memory orders (one memory bit, `createStatefulOrder`): the Memory switch on the create form doubles the cases and
  adds two columns to the grid. `s` is the memory a case starts with (the case number's bit above the inputs);
  `s′` is the memory the circuit must leave, packed above the outputs in each answer (`table.js`, `TableLib.sol`).
  The contract checks these orders with the circuit's `step` function instead of `eval`.
- Input names: optional, one per input and one for the memory bit, up to 32 bytes each, stored on chain as
  `bytes32` (`labelsOf`). With no names the page uses the label-less `createOrder` / `createStatefulOrder`.
  Names are arbitrary bytes, so the page removes control and text-direction characters when it reads them
  (`cleanName` in `table.js`), shows each name inside `<bdi>` and keeps the column code (`x0`, `s`) outside it, so
  no name can make a header read as another column. The create form refuses a name holding such characters.
- Receipt view, `?receipt=N`: needs no wallet. It shows what the contract wrote at payout (processor, circuit,
  table fingerprint, block), checks the fingerprint against the stored table and shape (the contract hashes
  `abi.encodePacked(nIn, nOut, nState, table)`) and `ruleOf` against the receipt, and lets a visitor run the paid circuit (`run`, or `runStep` with memory) as a free `eth_call`. The call asks for
  `(RUN_OVERHEAD + netlist + one case's hold) x 64/63` gas (for a pieced order: every piece's netlist and hold; for an order paid with a top circuit: every piece's netlist and one hold for the top's budget, `evalBudget(top gates) + EVAL_GAS_PER_REF × pieces`, read from the contract) (`gas.js`; the 64/63 is for the hop into the linked library `LatheReads`, which gets 63/64 of the gas). If that is above the 48M the page keeps under the
  public node's cap, the page says so and does not call. If a node gives the call less gas anyway, the contract
  reverts `InsufficientGasForCase` and the page shows that as an error. It never shows an answer it did not get
  in full. While a call is out the 0/1 switches are off; an answer that comes back after the view changed (reload,
  another order, another network) or for switches that no longer match is dropped, and any change to a switch
  clears the shown answer. The deliver box's processor and circuit boxes are off the same way while a read-out
  or a delivery is out.
- Pieced orders (`createPiecedOrder`, found with `piecesOf`): read only for now; creating and delivering pieces
  through the page comes later.
  - `?order=N` says how many pieces the order has and how they join (piece 2 gets piece 1's outputs in its low
    inputs, then the order's remaining inputs). Each piece shows its rule in plain words (a table, "a is at least b"
    or "a plus b" with the bit widths and which piece inputs are a and b, lowest bit first), its inputs and outputs,
    its own gate cap (`pieceMaxGatesOf`), and its state from `pieceOf`: not delivered, being checked (n of 2^nIn),
    or passed. A rejected piece shows as not delivered, because the contract clears its delivery. There is no deliver
    or check box; the page says pieces are delivered with `deliverPiece` and checked with `checkPiece` (the crank
    script, `scripts/README.md`). The refund box follows `refund()` for pieced orders: only while Open, right after
    the deadline while some piece has no delivery, otherwise one day after the deadline.
  - Wired orders (V4, `createPiecedOrder` with a `PiecedSpec`, up to 8 pieces): the view reads `wiresOf` and
    `needsTop` (a contract without them reads as the fixed join and "Lathe joins"). It shows how many pieces have
    passed ("2 of 3 pieces passed"), and, when the wires are not the fixed join, lists them in plain words, one line
    per run of wires ("Piece 2 inputs 2 to 4 come from piece 1 outputs 0 to 2"). An order that needs a top circuit
    gets a "Top circuit" box: waiting for the pieces, waiting for `deliverTop` (until one day after the deadline), or
    the delivered top (`deliveries(N)`). The page does not create wired orders; `examples/daily-cap.json` is made
    with cast or a script.
  - `?receipt=N` checks the fingerprint the same way the contract makes it, `keccak256(abi.encode(pieces, tables))`,
    against both the receipt and `piecedHash(N)` (with `wiresOf` added, `keccak256(abi.encode(pieces, tables,
    wires))`, for a wired order; since `wiresOf` shows the fixed join for an order made without wires, both forms
    are tried), and lists each piece's circuit. A "needs a top" order names its top circuit and is checked with
    `ruleOf`; its "Try the rule" holds gas for every piece plus the top. A 2-piece order without a top has no single
    circuit: the page says so, never shows the receipt's zero processor, and does not call `ruleOf` (it reverts
    `NoSingleCircuit` by design). A 1-piece order names its circuit and is checked with `ruleOf` like a V0 order.
    "Try the rule" calls `run` with gas for every piece's netlist read and full hold, times 64/63 for the library
    hop (`runPiecedGasLimit`), and compares the answer with the join worked out in `pieces.js`. If that gas is
    above the 48M the page keeps under the public node's cap, it says it cannot run it and does not call. The
    same stale-answer rules as the V0 run apply.
- A network with no contract address (mainnet today) shows "Not on mainnet yet" for every link (`?receipt=N`,
  `?order=N`, the create form) and nothing that says it is loading.
- Claim fees is left out on purpose: `claimFees()` sends fees to the fixed fee recipient, so it is no use to a visitor.
- Explorer links: none. When checked on 2026-11-21, neither OKLink nor the OKX explorer resolved a known chain-1952
  transaction, so hashes are shown as copyable text. Set `explorerTx` in `config.js` once a format is confirmed.

## Tests

All commands run from the repo root. The browser tests use an existing Playwright install outside the repo
(default `~/Desktop/career-ops/node_modules/playwright`; set `PLAYWRIGHT_DIR` to use another). Nothing is installed
into the repo. Anvil signs for its own unlocked default account, so no private key is used anywhere.

```sh
# 1. Encoder and gas unit tests (vectors copied from the Solidity tests)
node --test web/test/

# 2. End to end on a local anvil: deploys the testnet mocks with script/DeployTestnet.s.sol, then through the page:
#    XOR order + honest circuit 1 = Paid; XOR order + wrong circuit 2 = refusal sentence + failing row, nothing sent;
#    short-deadline order, anvil time moved on, refund = Refunded
node web/test/e2e.mjs

# 3. Mainnet fork: deploys LatheOrders + a mock token on an anvil fork of X Layer and delivers the real
#    TapeOut XOR circuit (processor 0x839bdD6fa7A66416A609A735e11DE5411B98574e, id 1) through the page
node web/test/fork.mjs

# 4. Read-only against the live testnet contract, no wallet: orders 1, 2, 3 = Paid, Open, Refunded
node web/test/readonly.mjs

# 5. Fix-round checks through a proxy that caps eth_call at 50M gas like the public nodes: 4,000-gate circuit
#    checked to Paid, clipped simulation, reverted check, account switch mid-read, receipt not readable,
#    wrong-network bar, ticking gates, commas, fee line, outputs field, grid keys, at most one request in flight
node web/test/fixround.mjs

# 6. Screenshots at 1440x900 and 390x844, dark and light, EN and ZH; fails on horizontal scroll
SHOTS_DIR=/tmp/lathe-shots node web/test/shots.mjs

# 7. Memory circuits on a local anvil: 1 input + 1 memory bit, Toggle preset (table 0x3c, s and s′ columns);
#    honest toggle circuit 3 = Paid; circuit 4 (new memory wrong in case 3) = refusal naming x0=1 s=1, row 3
#    highlighted, nothing sent; a memory-free circuit on a memory order = shape mismatch in the read-out
node web/test/memory.mjs

# 8. Receipts and input names on a local anvil, through the 50M-cap proxy: named XOR and toggle orders paid; with
#    no wallet, ?receipt=N shows the receipt, checks the table fingerprint and ruleOf, uses the names as row
#    headers, and runs run / runStep on chain; an unpaid order has no receipt; a 4,000-gate circuit is not run
#    (and the contract refuses run at 50M gas); a run call cut to 150,000 gas shows an error, not an answer;
#    with every reply held 1.5 s: switches off while run is out, stale answers dropped; a name with U+202E shown
#    without it inside <bdi> and refused on the form; mainnet with no address shows the notice, never "Loading"
node web/test/receipt.mjs
```

```sh
# 9. Pieced orders on a local anvil, through the 50M-cap proxy, no wallet needed for the views: a paid two-piece
#    order (Add(2,2) then GreaterOrEqual(3,2)): pieces, join, receipt fingerprint = piecedHash, "no single circuit",
#    run on inputs where bit order matters; a piece mid-check (100 of 4,096) past its deadline with every piece
#    delivered (refund waits for the grace day); a rejected piece (shown as not delivered); a piece never delivered
#    past the deadline (refund open); a paid 1-piece order (ruleOf, run); a paid order of 1,600-gate pieces (the page
#    says it cannot run it); a paid 3-piece wired order (wires in plain words, wired fingerprint, run); a "needs a
#    top" order with its top minted on the mock REF processor and delivered (receipt names the top, ruleOf, run);
#    the same waiting for the top and waiting for a piece; Chinese wire text. Checks that no V0 text appears:
#    table mismatch, zero address, "no delivery", deliver box
node web/test/pieces.mjs

# 10. Declared per-case gas on a local anvil (mock circuit 5: honest 6-input parity whose first call in a
#     transaction is dearer): the page tests all 64 cases, proposes a declared gas, delivers with the 4-argument
#     deliver, and a 7 / 1 / 56 check split pays; the same circuit delivered with the 3-argument deliver is
#     rejected at case 7 under the 7 / 1 split; a case above 100M is refused before sending; cases that fail in a
#     test run are "could not test" and Deliver is off, with the measure-case-gas.mjs recipe (also when the other
#     cases were tested and need more than the formula); a cheap circuit is delivered as before; the far-deadline
#     warning in EN and ZH
node web/test/casegas.mjs

# 11. Feature detection through a busy node (a proxy that answers chosen reads itself): a -32005 rate limit or an
#     HTTP 429 on caseGasOf(0), or -32005 on EVAL_GAS_PER_REF, shows "could not read, try again" with the tool
#     off and nothing saved; Try again loads it and saves the positive result (keyed by chain id and address);
#     a real revert of caseGasOf (an older contract) shows the older-contract warning and is not saved; in an
#     order view, -32005 on caseGasOf(id) or piecesOf(id) is a read error with Try again
node web/test/detect.mjs
```

`node --test web/test/` also runs `pieces.test.mjs`: the join and piece answers, the wired rule (the fixed join as
wires, and `examples/daily-cap.json` against "cap >= spent + amount"), the plain-words wire runs, and the pieced
refund rule.

The browser tests turn off the page's CSP (`bypassCSP`) only so the testnet or mainnet entry can point at
`127.0.0.1`; `readonly.mjs` and `shots.mjs` run with the real CSP. Forge output for the tests goes to a temp folder,
so the repo's `broadcast/` record is not touched.

## Security notes

- Chain data and URL parameters reach the page only as text (`textContent`), never `innerHTML`.
- Addresses are checked with viem's `isAddress`. There is no private-key input of any kind.
- The CSP allows only this site, esm.sh, jsDelivr and the two X Layer RPC hosts. `frame-ancestors` cannot be set
  from a meta tag; set it as an HTTP header on the host if framing must be blocked.
