// The Lathe order, as a pure model. No DOM. The build imports it and the page
// runtime inlines it, so every number the figure shows comes from here.
//
// A buyer writes a rule as a full truth table, locks a coin, and names a builder.
// The builder delivers a chip. The contract runs every case through the chip and
// compares each answer with the table. All 64 match: the builder is paid. Any
// answer wrong: the delivery is refused and the coin stays locked. If nothing has
// passed by the deadline, the buyer takes the coin back.

export const INPUTS = 6;
export const CASES = 1 << INPUTS; // 64
export const FAULT_CASE = 36; // the faulty chip is wrong here: index 36 counting from 0, shown as "Case 37 of 64"

// Bit i of case c. Switch 0 is the least significant bit, so it flips every case.
export const bitOf = (c, i) => (c >> i) & 1;
export const bitsOf = (c) => Array.from({ length: INPUTS }, (_, i) => bitOf(c, i));

// The buyer's rule: 6-input parity (XOR of all six bits).
export const parityOf = (c) => {
  let p = 0;
  for (let i = 0; i < INPUTS; i++) p ^= bitOf(c, i);
  return p;
};

// The table card: 64 expected answers. 1 is a punched cell.
export const expected = Object.freeze(Array.from({ length: CASES }, (_, c) => parityOf(c)));

// Two chips: the good one matches the card everywhere, the faulty one is wrong
// on exactly one case.
export const CHIPS = Object.freeze({
  good: Object.freeze(expected.slice()),
  faulty: Object.freeze(expected.map((v, c) => (c === FAULT_CASE ? 1 - v : v))),
});

export function firstMismatch(answers) {
  for (let c = 0; c < CASES; c++) if (answers[c] !== expected[c]) return c;
  return -1;
}

// Timing of one run, in seconds.
export const RATE = 12; // cases per second
export const T = Object.freeze({
  lock: 1.1, // coin placed and card in, before the first case
  release: 0.45, // flap swings, then the latch pin pulls back
  travel: 1.6, // budget for the coin to roll into a tray (the build checks the physics fits)
  hold: 2.6, // pause on the end state before the next run
  refusedHold: 1.5, // how long "refused" holds before the deadline sweeps
  sweep: 2.4, // the deadline hand sweeps to its mark
  deadline: 16, // seconds of normal running the dial shows between start and mark
});

const ease = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x));

// The whole timeline of one run of a chip, from t = 0 (coin locked, check about to start).
export function runOf(chipName) {
  const answers = CHIPS[chipName];
  const fault = firstMismatch(answers);
  const checkAt = T.lock;
  if (fault < 0) {
    const decideAt = checkAt + CASES / RATE;
    const releaseAt = decideAt + T.release;
    return { chip: chipName, fault, checkAt, decideAt, releaseAt, to: "builder", endAt: releaseAt + T.travel + T.hold };
  }
  const refuseAt = checkAt + fault / RATE;
  const sweepAt = refuseAt + T.refusedHold;
  const decideAt = sweepAt + T.sweep; // the hand reaches the mark: refund
  const releaseAt = decideAt + T.release;
  return { chip: chipName, fault, checkAt, refuseAt, sweepAt, decideAt, releaseAt, to: "buyer", endAt: releaseAt + T.travel + T.hold };
}

// The deadline hand, 0 at the start, 1 on the deadline mark.
export function handAt(run, t) {
  const slow = (x) => Math.max(0, x) / T.deadline;
  if (run.fault < 0) return Math.min(slow(t), 0.95);
  if (t < run.sweepAt) return slow(t);
  const from = slow(run.sweepAt);
  return from + (1 - from) * ease((t - run.sweepAt) / T.sweep);
}

// Everything the figure shows at time t of a run.
export function stateAt(run, t) {
  const answers = CHIPS[run.chip];
  const s = {
    chip: run.chip,
    phase: "locked",
    caseIndex: -1, // the case under test (0-based), -1 before the first
    n: 0, // the case number shown, counting from 1
    bits: bitsOf(0),
    answer: null,
    expect: null,
    lamp: "off", // "on" = the chip's answer matches the card, "alarm" = it does not
    counter: 0,
    flap: "buyer", // the coin goes back to the buyer unless the check passes
    latch: "held",
    to: null,
    releaseAt: run.releaseAt,
    hand: handAt(run, t),
    readout: "rLocked",
    done: t >= run.endAt,
  };
  if (t < run.checkAt) return s;
  const k = Math.min(CASES - 1, Math.floor((t - run.checkAt) * RATE));
  const at = (c) => {
    s.caseIndex = c;
    s.n = c + 1;
    s.bits = bitsOf(c);
    s.answer = answers[c];
    s.expect = expected[c];
    s.counter = c + 1;
  };
  if (run.fault < 0) {
    if (t < run.decideAt) {
      at(k);
      s.phase = "checking";
      s.lamp = "on";
      s.readout = "rChecking";
      return s;
    }
    at(CASES - 1);
    s.phase = "paid";
    s.lamp = "on";
    s.flap = "builder";
    s.latch = t >= run.releaseAt ? "open" : "held";
    s.to = "builder";
    s.readout = "rPaid";
    return s;
  }
  if (t < run.refuseAt) {
    at(k);
    s.phase = "checking";
    s.lamp = "on";
    s.readout = "rChecking";
    return s;
  }
  at(run.fault);
  s.lamp = "alarm";
  if (t < run.decideAt) {
    s.phase = "refused";
    s.readout = "rRefused";
    return s;
  }
  s.phase = "refunded";
  s.lamp = "off";
  s.latch = t >= run.releaseAt ? "open" : "held";
  s.to = "buyer";
  s.readout = "rRefunded";
  return s;
}

// The tour: good, faulty, good, faulty...
export const tourChip = (loop) => (loop % 2 === 0 ? "good" : "faulty");

// The coin's flight once the latch opens: a disc rolling down a slope (it
// accelerates at two thirds of g·sin θ, because some energy goes into spin),
// thrown off the end of a rail, stopped by an end wall, landing on edge in a
// tray and tipping flat. Pure: the geometry comes in, samples come out.
// g is in world units per second squared (the bench is drawn about 1 unit = 5 mm).
export function coinFlight(geo, to) {
  const { g, r, th } = geo;
  const K = geo.k || 1; // the chute's scale: wall and window sizes below are in its old units
  const half = (geo.ct || 1.2) / 2;
  const s = Math.sin(th);
  const c = Math.cos(th);
  const trunkZ = (y) => geo.trunk.z0 - (geo.trunk.y0 - y) * Math.tan(th);
  const railAZ = (y) => geo.railA.z0 - (y - geo.railA.y0) * Math.tan(th);
  const out = [];
  const dt = 1 / 2400;
  const every = 10; // keep one sample in ten: 240 per second
  let t = 0;
  let [y, z] = geo.start;
  let vy = 0;
  let vz = 0;
  let spin = 0;
  let mode = "roll"; // roll on the trunk line (going -y), "rollA" on rail A (going +y), "fly", "tip"
  let tray = to === "builder" ? geo.trayB : geo.trayA;
  let tipAt = 0;
  let landY = 0;
  const roll = 1 / 0.18;
  const keep = (step) => {
    if (step % every) return;
    const tip = mode === "tip" ? Math.min(1, (t - tipAt) * roll) : 0;
    const e = tip * tip * (3 - 2 * tip);
    const a = (e * Math.PI) / 2;
    let dx = 0;
    let zz = z;
    if (mode === "tip") {
      const px = -half; // rotate about the coin's front lower edge
      const pz = r;
      dx = px * Math.cos(a) + pz * Math.sin(a) + half;
      zz = tray.z + (-px * Math.sin(a) + pz * Math.cos(a));
    }
    const inTray = z - r < (to === "builder" ? geo.rimB : geo.rimA) + 0.01 && y > tray.y0 - 1 && y < tray.y1 + 1;
    out.push({ t: Math.round(t * 1e4) / 1e4, x: Math.round(dx * 1e3) / 1e3, y: Math.round(y * 1e3) / 1e3, z: Math.round(zz * 1e3) / 1e3, spin: Math.round(spin * 1e3) / 1e3, tip: Math.round(e * 1e3) / 1e3, layer: inTray || mode === "tip" ? "tray" : "chute", landed: mode === "tip" && tip >= 1 });
  };
  const yEndRoll = to === "builder" ? geo.railB.y1 : geo.trunk.y1;
  for (let step = 0; step < 2400 * 4; step++) {
    if (mode === "roll") {
      const a = (2 / 3) * g * s;
      const speed = Math.hypot(vy, vz) + a * dt;
      vy = -speed * c;
      vz = -speed * s;
      y += vy * dt;
      z = trunkZ(y + r * s) + r * c; // centre stays r off the floor line
      spin += (-vy / r) * dt;
      if (y + r * s < yEndRoll) mode = "fly";
    } else if (mode === "rollA") {
      const a = (2 / 3) * g * s;
      const speed = Math.max(0, Math.hypot(vy, vz)) + a * dt;
      vy = speed * c;
      vz = -speed * s;
      y += vy * dt;
      z = railAZ(y - r * s) + r * c;
      spin += (-vy / r) * dt;
      if (y - r * s > geo.railA.y1) mode = "fly";
    } else if (mode === "fly") {
      vz -= g * dt;
      y += vy * dt;
      z += vz * dt;
      spin += (-vy / r) * dt * 0.6;
      // end walls and the hanging flap
      if (to === "builder" && y - r < geo.stopB && vy < 0) {
        y = geo.stopB + r;
        vy = -vy * 0.3;
      }
      if (to === "buyer" && y > geo.trunk.y1 - 0.5 && y < geo.trunk.y1 + 30 * K && vy > 0 && y + r > geo.stopA) {
        y = geo.stopA - r;
        vy = -vy * 0.3;
      }
      if (to === "buyer" && vy < 0 && y - r < geo.flapWall && z > geo.railA.z0 - 12 * K) {
        y = geo.flapWall + r;
        vy = -vy * 0.3;
      }
      // the buyer's coin lands on rail A and rolls back toward +y
      if (to === "buyer" && y < geo.railA.y1 && y > geo.railA.y0 && vz < 0) {
        const contactY = y - r * s;
        const floor = railAZ(contactY) + r * c;
        if (z <= floor && z > floor - 3 * K && mode === "fly" && !landY) {
          z = floor;
          const along = vy * c - vz * s; // keep only the part of the velocity along the rail
          vy = Math.max(0, along) * c;
          vz = -Math.max(0, along) * s;
          mode = "rollA";
          landY = y;
        }
      }
      // the tray: walls and floor
      if (y - r < tray.y0 && vy < 0 && z - r < tray.z + 4 * K) {
        y = tray.y0 + r;
        vy = -vy * 0.3;
      }
      if (y + r > tray.y1 && vy > 0 && z - r < tray.z + 4 * K) {
        y = tray.y1 - r;
        vy = -vy * 0.3;
      }
      if (z - r <= tray.z && y > tray.y0 && y < tray.y1) {
        z = tray.z + r;
        vy = 0;
        vz = 0;
        mode = "tip";
        tipAt = t;
      }
    }
    keep(step);
    if (mode === "tip" && t - tipAt > 0.2) {
      t += dt;
      keep(0);
      break;
    }
    t += dt;
  }
  return out;
}
