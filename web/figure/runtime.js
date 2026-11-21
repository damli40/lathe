// Page runtime for the order test bench. Inlined into web/figure.js after the model
// (CASES, CHIPS, runOf, stateAt, coinFlight...), DATA, COIN_ART, SVG, LABEL, SWATCHES
// and DEFAULT_STRINGS. It writes attributes on refs; nothing re-renders per frame.

let MOUNTS = 0;
const escapeText = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const smoothstep = (a, b, x) => {
  const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const B = DATA.basis;
const screenOf = ([x, y, z]) => [B.o[0] + B.x[0] * x + B.y[0] * y + B.z[0] * z, B.o[1] + B.x[1] * x + B.y[1] * y + B.z[1] * z];
const offsetOf = ([x, y, z]) => [B.x[0] * x + B.y[0] * y + B.z[0] * z, B.x[1] * x + B.y[1] * y + B.z[1] * z];
const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;
const SWAP = 0.72; // seconds: lift the chip, change it, set it down
const QUIET = 3.6; // seconds without a click before the tour moves on
const FLIGHTS = { builder: coinFlight(DATA.geom, "builder"), buyer: coinFlight(DATA.geom, "buyer") };
const REST = { x: 0, y: DATA.geom.start[0], z: DATA.geom.start[1], spin: 0, tip: 0, layer: "chute" };

function poseAlong(flight, time) {
  if (time <= 0) return REST;
  const last = flight[flight.length - 1];
  if (time >= last.t) return last;
  let lo = 0;
  let hi = flight.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (flight[mid].t <= time) lo = mid;
    else hi = mid;
  }
  const a = flight[lo];
  const b = flight[hi];
  const f = (time - a.t) / (b.t - a.t || 1);
  return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f, spin: a.spin + (b.spin - a.spin) * f, tip: a.tip + (b.tip - a.tip) * f, layer: f < 0.5 ? a.layer : b.layer };
}
// where the coin is at time t of a run
function coinOf(run, t) {
  if (t < run.releaseAt) return { ...REST, to: run.to };
  return { ...poseAlong(FLIGHTS[run.to], t - run.releaseAt), to: run.to };
}

function template(id, strings) {
  const s = (key) => escapeText(strings[key] ?? "");
  const key = (mark, name) => `<span class="iso-key">${SWATCHES[mark]}<span data-s="${name}">${s(name)}</span></span>`;
  return (
    `<div class="lathe-fig" data-theme="dark" data-chip="good">` +
    `<figure class="iso-figure lf-figure">` +
    `<div class="iso-plate lf-plate">` +
    `<div class="lf-row lf-top" aria-hidden="true"><span class="iso-plate-corner" data-corner="fig" data-s="fig">${s("fig")}</span><span class="iso-plate-corner" data-corner="title" data-s="title">${s("title")}</span></div>` +
    `<div class="iso-stage lf-stage">${SVG.replace(/__ID__/g, id).replace("__LABEL__", escapeText(strings.svgLabel || LABEL))}</div>` +
    `<div class="lf-row lf-bottom"><span class="iso-plate-corner" data-corner="hint" data-s="hint" aria-hidden="true">${s("hint")}</span><span class="iso-plate-corner" data-corner="readout" data-readout aria-hidden="true"></span></div>` +
    `<span class="lf-sr" role="status" aria-live="polite"></span>` +
    `</div>` +
    `<figcaption class="iso-legend"><span class="iso-keys">${key("lit", "kChip")}${key("flat", "kCard")}${key("raised", "kLatch")}</span><span class="iso-caption" data-s="caption">${s("caption")}</span></figcaption>` +
    `</figure></div>`
  );
}

export function mountFigure(host, { theme = "dark", strings = DEFAULT_STRINGS } = {}) {
  const id = `lf${++MOUNTS}`;
  let words = { ...DEFAULT_STRINGS, ...strings };
  host.innerHTML = template(id, words);
  const root = host.firstElementChild;
  root.dataset.theme = theme === "light" ? "light" : "dark";
  const $ = (sel) => root.querySelector(sel);
  const svg = $("svg");
  const el = {
    readout: $("[data-readout]"),
    live: $(".lf-sr"),
    hint: $('[data-s="hint"]'),
    hit: $('[data-part="hit"]'),
    chip: $('[data-part="chip"]'),
    switches: [...root.querySelectorAll("[data-sw]")].sort((a, b) => a.dataset.sw - b.dataset.sw),
    mark: $('[data-part="mark"]'),
    lamp: $('[data-part="lamp"]'),
    tens: $('[data-part="drum-tens"]'),
    units: $('[data-part="drum-units"]'),
    hand: $('[data-part="hand"]'),
    flap: $('[data-part="flap"]'),
    pin: $('[data-part="pin"]'),
    pinClip: root.querySelector(`#${id}-pin path`),
    layers: { chute: $('[data-part="coin-chute"]'), trayA: $('[data-part="coin-trayA"]'), trayB: $('[data-part="coin-trayB"]') },
  };
  // narrow hosts get a tighter frame and stacked text; set before first paint so nothing shifts
  const frameFor = (width) => {
    const narrow = width > 0 && width < DATA.narrowBelow;
    if (narrow === (root.dataset.narrow === "")) return;
    if (narrow) root.dataset.narrow = "";
    else delete root.dataset.narrow;
    svg.setAttribute("viewBox", (narrow ? DATA.narrow : DATA.wide).join(" "));
  };
  frameFor(host.clientWidth);
  let sizer = null;
  if (typeof ResizeObserver === "function") {
    sizer = new ResizeObserver((entries) => frameFor(entries[entries.length - 1].contentRect.width));
    sizer.observe(host);
  }
  const still = typeof matchMedia === "function" ? matchMedia("(prefers-reduced-motion: reduce)") : { matches: false, addEventListener() {}, removeEventListener() {} };
  const NS = "http://www.w3.org/2000/svg";
  function makeCoin() {
    const g = document.createElementNS(NS, "g");
    g.setAttribute("class", "lf-coin");
    const body = document.createElementNS(NS, "g");
    const mark = document.createElementNS(NS, "path");
    mark.setAttribute("class", "iso-line");
    mark.setAttribute("data-tone", "lo");
    mark.setAttribute("data-free", "");
    g.append(body, mark);
    return { g, body, mark, art: -1, layer: "", visible: true };
  }
  const coin = makeCoin();
  const ghost = makeCoin(); // the previous run's coin, fading out of its tray
  ghost.g.setAttribute("opacity", "0");

  // ------------------------------------------------------------ state
  let chip = "good";
  let run = runOf(chip);
  let t = run.checkAt - 0.4; // start just before the first case
  let clock = 0;
  let swapAt = -99; // clock time a chip swap started
  let swapTo = null;
  let lastClick = -99;
  let ghostPose = null;
  let ghostAt = -99;
  let drum = { p: 0 };
  let pinShare = 0;
  let frame = 0;
  let last = 0;
  let visible = false;
  let phaseSaid = "";
  const shown = { accent: "", bits: -1, mark: -2, lamp: "", flap: "", readout: "", hint: "", chip: "", hand: -1, tens: -1, units: -1, lift: -1, pin: -1 };

  const readoutOf = (st) => (words[st.readout] || "").replace("{n}", String(st.n));

  function placeCoin(c, pose) {
    const layerName = pose.layer === "tray" ? (pose.to === "builder" ? "trayB" : "trayA") : "chute";
    if (c.layer !== layerName) {
      el.layers[layerName].appendChild(c.g);
      c.layer = layerName;
    }
    const index = Math.max(0, Math.min(DATA.tips, Math.round(pose.tip * DATA.tips)));
    if (c.art !== index) {
      c.body.innerHTML = COIN_ART[index];
      c.art = index;
    }
    const [sx, sy] = screenOf([DATA.xc + pose.x, pose.y, pose.z]);
    c.g.setAttribute("transform", `translate(${r2(sx)} ${r2(sy)})`);
    if (index === 0) {
      const a = pose.spin;
      const F = DATA.face;
      const p = (rad) => [F.o[0] + (F.u[0] * Math.cos(a) + F.v[0] * Math.sin(a)) * rad, F.o[1] + (F.u[1] * Math.cos(a) + F.v[1] * Math.sin(a)) * rad];
      const [x0, y0] = p(0.5);
      const [x1, y1] = p(DATA.cr - 1.1);
      c.mark.setAttribute("d", `M${r2(x0)} ${r2(y0)}L${r2(x1)} ${r2(y1)}`);
    } else c.mark.setAttribute("d", "");
  }

  function draw(st, calm, dt) {
    // switches: switch i shows bit i of the case
    const bits = st.bits.reduce((a, b, i) => a | (b << i), 0);
    if (bits !== shown.bits) {
      el.switches.forEach((node, i) => node.toggleAttribute("data-on", !!st.bits[i]));
      shown.bits = bits;
    }
    // the current case on the card
    if (st.caseIndex !== shown.mark) {
      if (st.caseIndex < 0) el.mark.setAttribute("display", "none");
      else {
        el.mark.removeAttribute("display");
        const c = st.caseIndex;
        el.mark.setAttribute("transform", `translate(${r2(DATA.cell.x0 + (c % 8) * DATA.cell.pitch)} ${r2(DATA.cell.y0 + Math.floor(c / 8) * DATA.cell.pitch)})`);
      }
      shown.mark = st.caseIndex;
    }
    // comparator lamp: steady while every answer matches, blinking on a wrong answer
    const lampOn = st.lamp === "on" || (st.lamp === "alarm" && !calm && clock % 0.8 < 0.4);
    const lamp = lampOn ? "on" : "off";
    if (lamp !== shown.lamp) {
      el.lamp.toggleAttribute("data-on", lampOn);
      shown.lamp = lamp;
    }
    // counter drums
    if (calm || st.counter < drum.p - 0.5) drum.p = st.counter;
    else drum.p += (st.counter - drum.p) * (1 - Math.exp(-dt / 0.035));
    if (Math.abs(st.counter - drum.p) < 0.002) drum.p = st.counter;
    const u = drum.p % 10;
    const tens = Math.floor(drum.p / 10) + Math.max(0, u - 9);
    const uy = r2(-u * DATA.drum.pitch);
    const ty = r2(-(tens % 10) * DATA.drum.pitch);
    if (uy !== shown.units) {
      el.units.setAttribute("transform", `translate(0 ${uy})`);
      shown.units = uy;
    }
    if (ty !== shown.tens) {
      el.tens.setAttribute("transform", `translate(0 ${ty})`);
      shown.tens = ty;
    }
    // deadline hand
    const handA = r2(st.hand * DATA.clock.dead * Math.PI * 2 * 1000) / 1000;
    if (handA !== shown.hand) {
      const C = DATA.clock;
      const tip = screenOf([C.x + Math.sin(handA) * C.r, C.y - Math.cos(handA) * C.r, C.z]);
      const tail = screenOf([C.x - Math.sin(handA) * C.tail, C.y + Math.cos(handA) * C.tail, C.z]);
      el.hand.setAttribute("d", `M${r2(tail[0])} ${r2(tail[1])}L${r2(tip[0])} ${r2(tip[1])}`);
      shown.hand = handA;
    }
    // flap and latch pin
    if (st.flap !== shown.flap) {
      el.flap.setAttribute("data-flap", st.flap);
      shown.flap = st.flap;
    }
    const pinTarget = t >= run.releaseAt - 0.12 ? 1 : 0;
    pinShare = calm ? pinTarget : pinTarget ? Math.min(1, pinShare + dt / 0.12) : 0;
    if (pinShare !== shown.pin) {
      const [dx, dy] = offsetOf(DATA.pinAxis.map((v) => v * DATA.pinOut * pinShare));
      const text = pinShare ? `translate(${r2(dx)} ${r2(dy)})` : "";
      if (text) el.pin.setAttribute("transform", text);
      else el.pin.removeAttribute("transform");
      if (el.pinClip) {
        if (text) el.pinClip.setAttribute("transform", `translate(${r2(-dx)} ${r2(-dy)})`);
        else el.pinClip.removeAttribute("transform");
      }
      shown.pin = pinShare;
    }
    // chip lift during a swap
    const age = clock - swapAt;
    const lift = calm || age > SWAP ? 0 : DATA.lift * smoothstep(0, 0.28, age) * (1 - smoothstep(0.42, SWAP, age));
    const l2 = r2(lift);
    if (l2 !== shown.lift) {
      if (l2) {
        const [dx, dy] = offsetOf([0, 0, lift]);
        el.chip.setAttribute("transform", `translate(${r2(dx)} ${r2(dy)})`);
      } else el.chip.removeAttribute("transform");
      shown.lift = l2;
    }
    // one lit accent: the chip, until the coin is released; then the coin, until the next run
    const accent = t >= run.releaseAt ? "coin" : "chip";
    if (accent !== shown.accent) {
      root.dataset.accent = accent;
      shown.accent = accent;
    }
    if (chip !== shown.chip) {
      root.dataset.chip = chip;
      shown.chip = chip;
    }
    // coins
    placeCoin(coin, coinOf(run, t));
    if (t < 0 && ghostPose) coin.g.setAttribute("opacity", String(r2(smoothstep(-SWAP + 0.15, -0.05, t))));
    else coin.g.removeAttribute("opacity");
    if (ghostPose) {
      const fade = calm ? 0 : 1 - smoothstep(0, 0.45, clock - ghostAt);
      if (fade <= 0) {
        ghost.g.remove();
        ghost.layer = "";
        ghostPose = null;
      } else {
        placeCoin(ghost, ghostPose);
        ghost.g.setAttribute("opacity", String(r2(fade)));
      }
    }
    // words
    const text = readoutOf(st);
    if (text !== shown.readout) {
      el.readout.textContent = text;
      shown.readout = text;
    }
    const hint = words[chip === "good" ? "hint" : "hintFaulty"] || "";
    if (hint !== shown.hint) {
      el.hint.textContent = hint;
      shown.hint = hint;
    }
    if (st.phase !== phaseSaid) {
      if (st.phase !== "checking" && phaseSaid) el.live.textContent = text;
      phaseSaid = st.phase;
    }
  }

  // start a new run with the given chip; the chip lifts, changes and sets down first
  function startRun(next, { calm = false } = {}) {
    const old = coinOf(run, t);
    if (t >= run.releaseAt) {
      ghostPose = old;
      ghostAt = clock;
    } else ghostPose = null;
    chip = next;
    run = runOf(chip);
    if (calm) {
      t = run.endAt - 0.01;
      ghostPose = null;
      return;
    }
    swapAt = clock;
    t = -SWAP;
  }
  function swapChip() {
    lastClick = clock;
    startRun(chip === "good" ? "faulty" : "good", { calm: still.matches });
    kick();
  }

  function tick(now) {
    const dt = last ? Math.min((now - last) / 1000, 1 / 30) : 1 / 60;
    last = now;
    const calm = still.matches;
    if (!calm) {
      clock += dt;
      t += dt;
      if (t >= run.endAt && clock - lastClick > QUIET) startRun(chip === "good" ? "faulty" : "good");
    }
    draw(stateAt(run, Math.max(t, -1)), calm, dt);
    frame = visible && !calm ? requestAnimationFrame(tick) : 0;
  }
  function kick() {
    if (still.matches) {
      draw(stateAt(run, t), true, 0);
      return;
    }
    if (!frame && visible) {
      last = 0;
      frame = requestAnimationFrame(tick);
    }
  }
  const onMotion = () => {
    if (still.matches) {
      t = run.endAt - 0.01;
      ghostPose = null;
      ghost.g.remove();
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      draw(stateAt(run, t), true, 0);
    } else kick();
  };
  // reduced motion: one still frame of the paid state
  if (still.matches) {
    t = run.endAt - 0.01;
  }
  draw(stateAt(run, t), true, 0);

  const onClick = (event) => {
    event.preventDefault();
    swapChip();
  };
  const onKey = (event) => {
    if (event.key === "Enter" || event.key === " " || event.key === "Spacebar") {
      event.preventDefault();
      if (!event.repeat) swapChip();
    }
  };
  el.hit.addEventListener("click", onClick);
  el.hit.addEventListener("keydown", onKey);
  el.hit.setAttribute("aria-label", words.chipLabel);
  still.addEventListener?.("change", onMotion);
  let observer = null;
  if (typeof IntersectionObserver === "function") {
    observer = new IntersectionObserver(
      (entries) => {
        visible = entries[entries.length - 1].isIntersecting;
        if (visible) kick();
      },
      { rootMargin: "120px 0px" },
    );
    observer.observe(root);
  } else {
    visible = true;
    kick();
  }

  return {
    setStrings(next) {
      words = { ...DEFAULT_STRINGS, ...next };
      root.querySelectorAll("[data-s]").forEach((node) => {
        const name = node.getAttribute("data-s");
        if (name !== "hint") node.textContent = words[name] ?? "";
      });
      el.hit.setAttribute("aria-label", words.chipLabel);
      if (words.svgLabel) svg.setAttribute("aria-label", words.svgLabel);
      shown.readout = "";
      shown.hint = "";
      draw(stateAt(run, t), true, 0);
    },
    setTheme(next) {
      root.dataset.theme = next === "light" ? "light" : "dark";
    },
    destroy() {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      visible = false;
      observer?.disconnect();
      sizer?.disconnect();
      still.removeEventListener?.("change", onMotion);
      el.hit.removeEventListener("click", onClick);
      el.hit.removeEventListener("keydown", onKey);
      host.innerHTML = "";
    },
  };
}
