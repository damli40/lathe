// Start a local anvil and deploy the testnet mocks + LatheOrders with script/DeployTestnet.s.sol.
// Uses anvil's unlocked default account (--unlocked --sender), so no private key is typed or stored.
// Forge's broadcast, cache and build output go to a temp folder, so the repo's broadcast/ record is untouched.
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO, rpc } from "./lib.mjs";

export const ANVIL_ACCOUNT0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // anvil's public default account

export async function startAnvil({ port = 8547, chainId = 1952, forkUrl = null, forkBlock = null } = {}) {
  const args = ["--port", String(port), "--gas-limit", "210000000", "--silent"];
  if (forkUrl) {
    args.push("--fork-url", forkUrl, "--compute-units-per-second", "50", "--fork-retry-backoff", "1000", "--retries", "10");
    if (forkBlock) args.push("--fork-block-number", String(forkBlock));
  } else args.push("--chain-id", String(chainId));
  const proc = spawn("anvil", args, { stdio: ["ignore", "ignore", "inherit"] });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i++) {
    try {
      await rpc(url, "eth_chainId");
      return { url, proc, stop: () => proc.kill("SIGTERM") };
    } catch {
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  proc.kill();
  throw new Error("anvil did not start");
}

function forgeEnv() {
  const tmp = mkdtempSync(join(tmpdir(), "lathe-forge-"));
  return { ...process.env, FOUNDRY_BROADCAST: join(tmp, "broadcast"), FOUNDRY_CACHE_PATH: join(tmp, "cache"), FOUNDRY_OUT: join(tmp, "out") };
}

/** Run DeployTestnet.s.sol against the anvil; returns { lathe, token, factory, processor }. */
export function deployMocks(url) {
  const out = execFileSync("forge", ["script", "script/DeployTestnet.s.sol", "--rpc-url", url, "--broadcast", "--unlocked", "--sender", ANVIL_ACCOUNT0], { cwd: REPO, env: forgeEnv(), encoding: "utf8", maxBuffer: 1 << 24 });
  const grab = (k) => out.match(new RegExp(`${k}\\s+(0x[0-9a-fA-F]{40})`))?.[1];
  const r = { lathe: grab("LATHE"), token: grab("USDT"), factory: grab("FACTORY"), processor: grab("PROCESSOR") };
  if (!r.lathe || !r.token || !r.processor) throw new Error("could not read deploy output:\n" + out);
  return r;
}

/**
 * forge create, unlocked sender. Returns the deployed address. `libraries` are "path:Name:0xaddr" strings for the
 * linked libraries the contract calls (LatheOrders needs LatheChecks and LatheReads; see deployLathe).
 */
export function forgeCreate(url, contract, ctorArgs = [], libraries = []) {
  const args = ["create", contract, "--rpc-url", url, "--unlocked", "--from", ANVIL_ACCOUNT0, "--broadcast"];
  for (const l of libraries) args.push("--libraries", l);
  if (ctorArgs.length) args.push("--constructor-args", ...ctorArgs);
  const out = execFileSync("forge", args, { cwd: REPO, env: forgeEnv(), encoding: "utf8", maxBuffer: 1 << 24 });
  const a = out.match(/Deployed to:\s+(0x[0-9a-fA-F]{40})/)?.[1];
  if (!a) throw new Error("forge create failed:\n" + out);
  return a;
}

/** Deploy LatheOrders with forge create: its two linked libraries first, then the contract linked to them. */
export function deployLathe(url, ctorArgs) {
  const checks = forgeCreate(url, "src/LatheChecks.sol:LatheChecks");
  const reads = forgeCreate(url, "src/LatheReads.sol:LatheReads");
  return forgeCreate(url, "src/LatheOrders.sol:LatheOrders", ctorArgs, [
    `src/LatheChecks.sol:LatheChecks:${checks}`,
    `src/LatheReads.sol:LatheReads:${reads}`,
  ]);
}
