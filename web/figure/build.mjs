// Build the Lathe hero figure: an order test bench with a coin latch.
//
//   node web/figure/build.mjs            writes web/figure.js and web/figure.css
//   node web/figure/build.mjs --audit    also proves the geometry (ends "audit passed")
//   node web/figure/build.mjs --preview <dir>   also writes standalone preview pages to <dir>
//
// The drawing is made with the Anatomy kit (MIT, copied into ./kit). Every number
// the figure shows comes from ./model.mjs, which the page runtime inlines.
//
// Parts list (grouped as the skill asks; every part sits on another part):
//   base       plate, six feet (flange + foot), groove, seam, corner screws, ruler strip, label plate
//   switches   bank housing, panel, panel screws, six toggles (nut, threaded bushing, bat, tip ball),
//              index marks, connector shell
//   fixture    socket base, ZIF body, contact holes, lever boss, lever, lever knob, chip (body, 14 pins),
//              spare-chip foam pad and the spare chip
//   card       holder base, front lip, back rib, the table card (8 x 8 cells), current-case marker
//   comparator housing, lid seam, lamp collar, knurled bezel, lens, counter window with two drums,
//              reset knob, screws
//   coin board stand, back board, rivets, trunk rail, flap, rail to the builder, rail back to the buyer,
//              lips, end stops, end block, latch pin and gland, latch driver box, two trays, the coin
//   clock      pedestal, dial puck, knurled bezel, ticks, deadline mark, hub, crown, hand
//   cables     switches to socket, socket to comparator, comparator to latch (each with two shells)

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as k from "./kit/iso-kit.mjs";
import * as G from "./kit/lathe.mjs";
import { tubePieces, tubeSvg } from "./kit/tube.mjs";
import * as A from "./kit/audit.mjs";
import * as M from "./model.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = resolve(HERE, "..");
const argv = process.argv.slice(2);
const previewAt = argv.indexOf("--preview");
const PREVIEW = previewAt >= 0 ? resolve(argv[previewAt + 1] || join(HERE, "..", "..", "..", "preview")) : null;

// ---------------------------------------------------------------- camera and the chassis outline
// An instrument chassis: a deep body on feet, a deck on top, and an upright back panel that
// carries the table card and the coin chute. Low parts stand on the deck in front of it.
const W = 600;
const H = 440;
const AZIMUTH = 32;
const ELEVATION = 30;
const PLATE = { x: -46, y: -108, w: 92, d: 216, r: 5 };
const PLATE_H = 22;
const FOOT_H = 6;
const FX = -40; // the panel's front face
const PANEL = { x0: -45, x1: FX, y0: -106, y1: 106, h: 98 };

const P = k.fitProjection(
  [...k.boxCorners({ x: PLATE.x, y: PLATE.y, w: PLATE.w, d: PLATE.d + 8, r: 0 }, -PLATE_H - FOOT_H, 0), [PANEL.x0, PANEL.y0, PANEL.h + 2.5], [PANEL.x0, PANEL.y1, PANEL.h + 2.5], [FX + 2, PANEL.y1, PANEL.h + 2.5]],
  W,
  H,
  { pad: 10, azimuth: AZIMUTH, elevation: ELEVATION },
);
const V = G.viewOf(P);
const KS = G.scaleOf(P);
const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const Ln = (d, style) => k.lineSvg(d, style);
const Dots = (points, style) => k.dotsSvg(points, style);
const path3 = (points, closed = false) => k.pathOf(points.map(at), closed);
const f2 = (v) => Math.round(v * 100) / 100;
const f3 = (v) => Math.round(v * 1000) / 1000;
const deg = Math.PI / 180;

const R = A.recorder(P);
const record = R.solid;
function put(name, ref, svg, shapes = [], { bias = 0, ...rest } = {}) {
  return R.put({ name, at: ref, bias, svg, shapes, piece: "bench", ...rest });
}
const back = []; // static parts drawn under everything (halo, feet, plate)

// ---------------------------------------------------------------- helpers
function box(name, plan, z, h, style = {}, { steps = 3, bevel = 0, extra = "", inner = "", bias = 0, ...rest } = {}) {
  const shape = record(A.slab(plan, z, h, { name, ...rest }, steps));
  put(name, [plan.x + plan.w / 2, plan.y + plan.d / 2, z + h / 2], S(k.slabOf(plan, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
function cyl(name, cx, cy, r, z, h, style = {}, { steps = 28, bevel = 0, extra = "", inner = "", bias = 0, ...rest } = {}) {
  const shape = record(A.cylinder(cx, cy, r, z, h, { name, ...rest }));
  put(name, [cx, cy, z + h / 2], S(k.cylinder(cx, cy, r, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
const XF = G.frameOf([0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
// a board: polygon in (y, z) extruded along x from x0 to x1
function board(name, poly, x0, x1, style = {}, { extra = "", inner = "", bias = 0, ref, ...rest } = {}) {
  const shape = record(A.prism(XF, poly, x0, x1, { name, ...rest }));
  const cy = poly.reduce((a, p) => a + p[0], 0) / poly.length;
  const cz = poly.reduce((a, p) => a + p[1], 0) / poly.length;
  put(name, ref ?? [(x0 + x1) / 2, cy, cz], S(G.prismOf(XF, poly, x0, x1, P), { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
function prism(name, F, poly, s0, s1, style = {}, { extra = "", inner = "", bias = 0, ref, ...rest } = {}) {
  const shape = record(A.prism(F, poly, s0, s1, { name, ...rest }));
  const cx = poly.reduce((a, p) => a + p[0], 0) / poly.length;
  const cy = poly.reduce((a, p) => a + p[1], 0) / poly.length;
  const centre = G.add3(G.add3(G.add3(F.o, G.mul3(F.a, (s0 + s1) / 2)), G.mul3(F.u, cx)), G.mul3(F.v, cy));
  put(name, ref ?? centre, S(G.prismOf(F, poly, s0, s1, P), { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
function turned(name, F, profile, style = {}, { extra = "", inner = "", bias = 0, smooth, steps, owner, radius } = {}) {
  const opts = { ...(smooth !== undefined ? { smooth } : {}), ...(steps ? { steps } : {}) };
  const paths = G.solidOf(profile, F, P, opts);
  const mid = (profile[0][0] + profile[profile.length - 1][0]) / 2;
  const shape = record(A.solid(F, profile, { name, owner, radius: radius ?? null }));
  put(name, G.add3(F.o, G.mul3(F.a, mid)), S(paths, { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
const discOn = (name, F, s0, s1, r, style = {}, options = {}) => turned(name, F, [[s0, r], [s1, r]], style, options);
const hexRing = (cx, cy, r, phase = 0) => Array.from({ length: 6 }, (_, i) => [cx + r * Math.cos(phase + (i * Math.PI) / 3), cy + r * Math.sin(phase + (i * Math.PI) / 3)]);
function planeMatrix(o, ex, ey) {
  const p0 = at(o);
  const px = at(G.add3(o, ex));
  const py = at(G.add3(o, ey));
  const v = (x) => x.toFixed(4);
  return `matrix(${v(px[0] - p0[0])} ${v(px[1] - p0[1])} ${v(py[0] - p0[0])} ${v(py[1] - p0[1])} ${p0[0].toFixed(2)} ${p0[1].toFixed(2)})`;
}
const screws = (points, z, r = 1.6) =>
  Ln(points.map(([x, y]) => k.ring(x, y, r, z, P, 14)).join(""), { tone: "lo" }) + Dots(points.map(([x, y]) => at([x, y, z])), { size: 0.45 });

const CABLES = [];
function cable(name, points, r = 0.8, { tone = "mid", bend = 3.4 } = {}) {
  const route = G.fillet(points, Math.max(bend, r * 2.6), 10, { P, tube: r });
  const total = G.pathLength(route);
  const SHELL = 2.2;
  const SHELL_R = 1.45;
  const gaps = [[0, SHELL], [total - SHELL, total]];
  R.route(name, route, r, { gaps, limp: true, touch: ["stand.plate", `${name}.shell*`], rims: [r * SHELL_R, r * SHELL_R], piece: "bench" });
  CABLES.push(name);
  tubePieces(route, r, P, { maxLength: 14, spacing: 0.9, gaps, rings: { pitch: 1.6, fade: [0.15, 0.6], tone: "faint" } }).forEach((piece, index) =>
    put(`${name}:${index}`, piece.mid, tubeSvg(piece, { tone }), [A.tube(piece.points, piece.radii)], { bias: 0.05 }),
  );
  [0, 1].forEach((index) => {
    const tangent = G.tangentAlong(route, index ? total : 0);
    const end = index ? route[route.length - 1] : route[0];
    const F = G.frameAlong(end, tangent);
    const [s0, s1] = index ? [-SHELL, 0] : [0, SHELL];
    const shape = record(A.disc(F, s0, s1, r * SHELL_R, { name: `${name}.shell${index}`, owner: name }));
    put(`${name}.shell${index}`, G.add3(end, G.mul3(tangent, (s0 + s1) / 2)), S(G.disc(s0, s1, r * SHELL_R, F, P, { steps: 24, bevel: 0.2 }), { tone: "mid" }) + Ln(G.arcOf(F, (s0 + s1) / 2, r * SHELL_R, P), { tone: "faint" }), [shape], { bias: 0.15 });
  });
  return route;
}

// ---------------------------------------------------------------- chassis
back.push(`<path class="iso-halo" d="${k.haloOf(PLATE, -PLATE_H - FOOT_H, PLATE_H, P)}"/>`);
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));
const FEET = [...k.corners(PLATE, 13), [PLATE.x + 13, 0], [PLATE.x + PLATE.w - 13, 0]];
for (const [x, y] of byDepth(FEET)) {
  back.push(S(k.cylinder(x, y, 7.4, -PLATE_H - FOOT_H, 1.8, P, 28), { tone: "lo" }));
  back.push(S(k.cylinder(x, y, 5.6, -PLATE_H - FOOT_H + 1.8, FOOT_H - 1.8, P, 28), { tone: "mid" }));
}
{
  // body: a bottom trim seam and a lid seam just under the deck
  const inner = Ln(k.sideSeam(PLATE, -PLATE_H + 4, P, 8), { tone: "lo" }) + Ln(k.sideSeam(PLATE, -3.2, P, 8), { tone: "lo" });
  back.push(S(k.slabOf(PLATE, -PLATE_H, PLATE_H, P, 8, 1.4), { tone: "hi", inner }));
}
back.push(Ln(k.planOutline(k.insetPlan(PLATE, 3.4), 0, P), { tone: "lo" }));
back.push(screws(k.corners(PLATE, 7), 0, 1.8));
record(A.slab(PLATE, -PLATE_H, PLATE_H, { name: "stand.plate", ground: true }, 8));

// the front face (+x): ventilation slots, a label plate, four screws
const FRONT = PLATE.x + PLATE.w;
{
  const slots = [];
  for (let i = 0; i < 9; i++) {
    const y = -96 + i * 5.2;
    slots.push(path3([[FRONT, y + 0.6, -7], [FRONT, y - 0.6, -7], [FRONT, y - 0.6, -15], [FRONT, y + 0.6, -15]], true));
  }
  const fscrews = [[-102, -6.5], [-102, -15.5], [102, -6.5], [102, -15.5]].map(([y, z]) => at([FRONT, y, z]));
  back.push(Ln(slots.join(""), { tone: "lo" }) + Ln(path3([[FRONT, -99, -5], [FRONT, -50.4, -5], [FRONT, -50.4, -17], [FRONT, -99, -17]], true), { tone: "lo" }) + Dots(fscrews, { size: 0.6, tone: "mid" }));
}
{
  const poly = [[60, -6], [20, -6], [20, -15.6], [60, -15.6]];
  const fx = FRONT + 0.6;
  const rules = [[56, -9, 22], [56, -11.4, 30], [56, -13.6, 16]].map(([y, z, len]) => path3([[fx, y, z], [fx, y - len, z]])).join("");
  board("front.label", poly, FRONT, fx, { tone: "lo", crease: "none" }, { extra: Ln(rules, { tone: "mid", free: true }) + Dots([at([fx, 22, -10.8]), at([fx, 58, -10.8])], { size: 0.5, tone: "mid" }) });
}
// ruler strip along the deck's front edge, right of the switch bank
const STRIP = { x: 41.5, y: -102, w: 3.6, d: 150, r: 0.8 };
{
  const ticks = k.topTicks(STRIP.y + 3, STRIP.y + STRIP.d - 3, 5, 5, STRIP.x, 0.6, [1.4, 2.6], P, "y");
  const extra = Ln(ticks.minor, { tone: "lo" }) + Ln(ticks.major, { tone: "mid" });
  box("strip", STRIP, 0, 0.6, { tone: "lo", crease: "none" }, { extra });
}
// carry handle on the near end face
{
  const face = PLATE.y + PLATE.d;
  const BAR_R = 1.8;
  const POST_R = 1.3;
  const reach = 6.4;
  const z = -PLATE_H / 2;
  const stop = reach - Math.sqrt(BAR_R * BAR_R - POST_R * POST_R);
  for (const x of [-30, 30]) discOn(`handle.post${x > 0 ? 1 : 0}`, G.frameOf([x, face, z], [0, 1, 0], [1, 0, 0], [0, 0, 1]), 0, stop, POST_R, { tone: "mid" }, { owner: "handle" });
  const barF = G.frameOf([-36, face + reach, z], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  discOn("handle.bar", barF, 0, 72, BAR_R, { tone: "mid", inner: Ln([-30, 30].map((x) => G.arcOf(barF, x + 36, BAR_R, P)).join(""), { tone: "faint" }) }, { owner: "handle" });
}

// ---------------------------------------------------------------- back panel
{
  const rivets = [];
  for (let y = -98; y <= 98; y += 28) for (const z of [4, PANEL.h - 4]) rivets.push(at([FX, y, z]));
  const seam = path3([[FX, PANEL.y1 - 2, 10], [FX, PANEL.y0 + 2, 10]]);
  board("panel", [[PANEL.y1, 0], [PANEL.y0, 0], [PANEL.y0, PANEL.h], [PANEL.y1, PANEL.h]], PANEL.x0, PANEL.x1, { tone: "mid" }, { extra: Dots(rivets, { size: 0.55, tone: "mid" }) + Ln(seam, { tone: "faint" }) });
  box("panel.cap", { x: PANEL.x0 - 0.6, y: PANEL.y0 - 0.6, w: PANEL.x1 - PANEL.x0 + 1.8, d: PANEL.y1 - PANEL.y0 + 1.2, r: 0.8 }, PANEL.h, 2.5, { tone: "mid" }, { steps: 2 });
  const RF = G.frameOf([0, 0, 0], [0, 1, 0], [1, 0, 0], [0, 0, 1]);
  for (const [name, y0] of [["gussetL", PANEL.y1 - 3], ["gussetR", PANEL.y0]]) prism(`panel.${name}`, RF, [[FX, 0], [FX + 13, 0], [FX, 34]], y0, y0 + 3, { tone: "mid" });
}


// a rating plate and a vent grille on the panel's empty upper right
{
  const fx = FX + 0.6;
  const grille = [];
  for (let i = 0; i < 7; i++) {
    const y = -64 - i * 5;
    grille.push(path3([[FX, y + 0.7, 58], [FX, y - 0.7, 58], [FX, y - 0.7, 48], [FX, y + 0.7, 48]], true));
  }
  const poly = [[-62, 64], [-98, 64], [-98, 84], [-62, 84]];
  const rules = [[-66, 79.5, 24], [-66, 76.5, 18], [-66, 73.5, 28], [-66, 70.5, 12]].map(([y, z, len]) => path3([[fx, y, z], [fx, y - len, z]])).join("");
  board("panel.plate", poly, FX, fx, { tone: "lo", crease: "none" }, { extra: Ln(rules, { tone: "mid", free: true }) + Dots([at([fx, -64, 82]), at([fx, -96, 82]), at([fx, -64, 66]), at([fx, -96, 66])], { size: 0.5, tone: "mid" }) + Ln(grille.join(""), { tone: "lo" }) });
}

// ---------------------------------------------------------------- switch bank (front left)
const BANK = { x: 12, y: 60, w: 29, d: 44, r: 2.4 };
const BANK_H = 9;
const SWP = { x: 13.5, y: 61.5, w: 26, d: 41, r: 1.6 };
const PANEL_TOP = BANK_H + 1.2;
const SW_X = 24;
const SW_Y = Array.from({ length: M.INPUTS }, (_, i) => 99 - i * 7);
box("bank", BANK, 0, BANK_H, { tone: "mid" }, { steps: 5, bevel: 0.8, inner: Ln(k.sideSeam(BANK, 3, P, 5), { tone: "lo" }) });
{
  const extra =
    screws(k.corners(SWP, 2.6), PANEL_TOP, 0.9) +
    Dots(SW_Y.map((y) => at([SW_X + 7, y, PANEL_TOP])), { size: 0.6, tone: "hi" }) +
    Ln(SW_Y.map((y) => k.ring(SW_X - 6, y, 0.6, PANEL_TOP, P, 12)).join(""), { tone: "lo" }) +
    Ln(k.lineOnTop([SWP.x + 20, SWP.y], [SWP.x + 20, SWP.y + SWP.d], PANEL_TOP, P), { tone: "faint" });
  box("bank.panel", SWP, BANK_H, 1.2, { tone: "mid" }, { steps: 4, bevel: 0.5, extra });
}
const BAT_TILT = 24 * deg;
const BAT_LEN = 8;
const TIP_R = 1.05;
function batOf(i, bit) {
  const pivot = [SW_X, SW_Y[i], PANEL_TOP + 1.2 + 2.6];
  const dir = [0, bit ? -Math.sin(BAT_TILT) : Math.sin(BAT_TILT), Math.cos(BAT_TILT)];
  const F = G.frameAlong(pivot, dir);
  const profile = [[0, 1.05], [BAT_LEN, 0.68]];
  const tipC = G.add3(pivot, G.mul3(dir, BAT_LEN + Math.sqrt(TIP_R * TIP_R - 0.68 * 0.68)));
  const svg = S(G.solidOf(profile, F, P), { tone: "hi" }) + S(G.sphereOf(tipC, TIP_R, P, { steps: 32 }), { tone: "hi" });
  const shapes = [record(A.solid(F, profile, { name: `sw${i}.bat${bit}`, owner: `sw${i}` })), record(A.ball(tipC, TIP_R, { name: `sw${i}.tip${bit}`, owner: `sw${i}` }))];
  return { svg, shapes, pivot };
}
SW_Y.forEach((y, i) => {
  const nutZ = PANEL_TOP;
  const ring = hexRing(SW_X, y, 2.3, Math.PI / 6);
  const nut = record(A.extruded(ring, nutZ, 1.2, { name: `sw${i}.nut` }));
  put(`sw${i}.nut`, [SW_X, y, nutZ + 0.6], S(k.extrude(ring, nutZ, 1.2, P), { tone: "mid" }), [nut]);
  const threads = [0.6, 1.3, 2].map((dz) => k.sideArc(SW_X, y, 1.5, nutZ + 1.2 + dz, P, 14)).join("");
  cyl(`sw${i}.bushing`, SW_X, y, 1.5, nutZ + 1.2, 2.6, { tone: "mid", inner: Ln(threads, { tone: "faint" }) }, { steps: 20, owner: `sw${i}` });
  const b0 = batOf(i, 0);
  const b1 = batOf(i, 1);
  put(`sw${i}.bat`, G.add3(b0.pivot, [0, 0, 4]), `<g class="lf-b0">${b0.svg}</g><g class="lf-b1">${b1.svg}</g>`, [...b0.shapes, ...b1.shapes], { attrs: ` data-sw="${i}"` });
});

// ---------------------------------------------------------------- fixture: socket and chip (front centre)
const SBASE = { x: -2, y: -2, w: 44, d: 56, r: 3 };
const SBASE_H = 7;
const ZIF = { x: 4, y: 3, w: 32, d: 46, r: 1.8 };
const ZIF_TOP = SBASE_H + 5;
const CHIP = { x: 12.5, y: 9, w: 15, d: 34, r: 0.8 };
const PITCH = 4.6;
const PIN0 = (CHIP.d - 6 * PITCH) / 2;
const CHIP_Z = ZIF_TOP + 2.6;
const CHIP_TOP = CHIP_Z + 4.2;
const PIN_Y = Array.from({ length: 7 }, (_, j) => CHIP.y + PIN0 + j * PITCH);
box("socket.base", SBASE, 0, SBASE_H, { tone: "mid" }, { steps: 5, bevel: 0.8, extra: screws(k.corners(SBASE, 3.4), SBASE_H, 1.2), inner: Ln(k.sideSeam(SBASE, 2.6, P, 5), { tone: "lo" }) });
{
  const holes = [];
  for (const x of [CHIP.x - 1.1, CHIP.x + CHIP.w + 1.1]) for (const y of [PIN_Y[0] - PITCH, ...PIN_Y, PIN_Y[6] + PITCH]) holes.push(k.ring(x, y, 0.65, ZIF_TOP, P, 10));
  const extra = Ln(holes.join(""), { tone: "lo" }) + Ln(k.planOutline(k.insetPlan(ZIF, 1.4), ZIF_TOP, P, 3), { tone: "faint" });
  box("socket.zif", ZIF, SBASE_H, 5, { tone: "mid" }, { steps: 3, bevel: 0.5, extra });
}
{
  const LX = ZIF.x + ZIF.w;
  const F = G.frameOf([LX, ZIF.y + ZIF.d - 3, SBASE_H + 2.6], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  discOn("socket.boss", F, 0, 1.4, 1.8, { tone: "mid" });
  box("socket.lever", { x: LX + 1.4, y: ZIF.y - 1, w: 2, d: ZIF.d - 1.2, r: 0.9 }, SBASE_H + 1.6, 2, { tone: "mid" }, { steps: 3 });
  cyl("socket.knob", LX + 2.4, ZIF.y, 1.6, SBASE_H + 3.6, 3.6, { tone: "mid", inner: "" }, { steps: 18, extra: Ln(k.knurl(LX + 2.4, ZIF.y, 1.6, SBASE_H + 3.6, SBASE_H + 7.2, 14, P, 0.25), { tone: "lo" }) });
}
// a chip drawn at its place on a part; used for the one in the socket and the spare
function chipArt(plan, z0, prefix, { lit = false, faulty = false } = {}) {
  const out = [];
  const shapes = [];
  const pinYs = Array.from({ length: 7 }, (_, j) => plan.y + PIN0 + j * PITCH);
  const bodyZ = z0 + 2.6;
  const BODY_H = 4.2;
  const top = bodyZ + BODY_H;
  const backPins = [];
  const frontPins = [];
  for (const y of pinYs) {
    for (const side of [0, 1]) {
      const x0 = side ? plan.x + plan.w : plan.x - 1.6;
      const legX = side ? plan.x + plan.w + 0.6 : plan.x - 1.6;
      const sh = { x: x0, y: y - 0.7, w: 1.6, d: 1.4, r: 0.25 };
      const leg = { x: legX, y: y - 0.5, w: 1, d: 1, r: 0.15 };
      const svg = S(k.slabOf(leg, z0, bodyZ + 1.3 - z0, P, 1), { tone: "mid", crease: "none" }) + S(k.slabOf(sh, bodyZ + 0.3, 1, P, 1), { tone: "mid", crease: "none" });
      shapes.push(A.slab(leg, z0, bodyZ + 1.3 - z0, { name: `${prefix}.leg` }, 1), A.slab(sh, bodyZ + 0.3, 1, { name: `${prefix}.pin` }, 1));
      (side ? frontPins : backPins).push({ y, svg });
    }
  }
  const sortY = (list) => list.sort((a, b) => b.y - a.y).map((p) => p.svg).join("");
  const notch = (() => {
    const cx = plan.x + plan.w / 2;
    const cy = plan.y + plan.d;
    const pts = Array.from({ length: 13 }, (_, i) => {
      const t = Math.PI + (i / 12) * Math.PI;
      return [cx + 2 * Math.cos(t), cy + 2 * Math.sin(t)];
    });
    return k.onTop(pts, top, P);
  })();
  let marks = Ln(notch, { tone: "lo" }) + Ln(k.ring(plan.x + 3, plan.y + plan.d - 3.4, 0.9, top, P, 14), { tone: "lo" });
  if (faulty) {
    // a bodge wire: a hand-soldered fix that went wrong, from pin 3 over the body to pin 10
    const a = [plan.x + plan.w + 0.8, pinYs[2], bodyZ + 1.3];
    const b = [plan.x - 0.8, pinYs[5], bodyZ + 1.3];
    const pts = [];
    for (let i = 0; i <= 24; i++) {
      const t = i / 24;
      const p = G.lerp3(a, b, t);
      p[2] = bodyZ + 1.3 + Math.sin(Math.PI * t) * (top - bodyZ - 1.3 + 1.1);
      pts.push(p);
    }
    marks += Ln(path3(pts), { tone: "hi" }) + Dots([at(a), at(b)], { size: 0.9, tone: "hi" });
  }
  const body = S(k.slabOf(plan, bodyZ, BODY_H, P, 2, 0.5), { tone: "hi", lit, crease: lit ? "lo" : "faint" });
  shapes.push(A.slab(plan, bodyZ, BODY_H, { name: `${prefix}.body` }, 2));
  out.push(sortY(backPins), body, marks, sortY(frontPins));
  return { svg: out.join(""), shapes, top };
}
{
  const good = chipArt(CHIP, ZIF_TOP, "chip", { lit: true });
  const bad = chipArt(CHIP, ZIF_TOP, "chipF", { lit: true, faulty: true });
  good.shapes.forEach(record);
  put("chip", [CHIP.x + CHIP.w / 2, CHIP.y + CHIP.d / 2, CHIP_Z + 2.1], `<g data-part="chip"><g class="lf-good">${good.svg}</g><g class="lf-faulty">${bad.svg}</g></g>`, good.shapes);
}
// spare chip on a conductive foam pad, in front of the card
const FOAM = { x: -31, y: 58, w: 24, d: 44, r: 2 };
const FOAM_H = 4.4;
const SPARE = { x: -26.5, y: 63, w: 15, d: 34, r: 0.8 };
box("foam", FOAM, 0, FOAM_H, { tone: "lo" }, { steps: 4, extra: Ln(k.planOutline(k.insetPlan(FOAM, 2.2), FOAM_H, P, 3), { tone: "faint" }) });
{
  const good = chipArt(SPARE, FOAM_H, "spare");
  const bad = chipArt(SPARE, FOAM_H, "spareF", { faulty: true });
  good.shapes.forEach(record);
  put("spare", [SPARE.x + SPARE.w / 2, SPARE.y + SPARE.d / 2, FOAM_H + 3.6], `<g class="lf-spare-good">${good.svg}</g><g class="lf-spare-faulty">${bad.svg}</g>`, good.shapes);
}

// ---------------------------------------------------------------- the table card, clipped flat to the back panel
const CARD_W = 66;
const CARD_HT = 70;
const CARD_T = 1.2;
const CARD_YC = 64;
const CARD_Z0 = 24;
const CARD_N = [1, 0, 0];
const CARD_U = [0, -1, 0];
const CARD_V = [0, 0, 1];
const CARD_O = [FX + CARD_T, CARD_YC, CARD_Z0]; // bottom centre of the card's front face
const CARD = G.frameOf(CARD_O, CARD_N, CARD_U, CARD_V);
{
  // a ledge the card stands on, with two screws, and two clips over the top corners
  const LEDGE = { x: FX, y: CARD_YC - CARD_W / 2 - 3, w: 5.4, d: CARD_W + 6, r: 0.8 };
  box("holder", LEDGE, CARD_Z0 - 3, 3, { tone: "mid" }, { steps: 3, extra: screws([[FX + 3.4, LEDGE.y + 2.6], [FX + 3.4, LEDGE.y + LEDGE.d - 2.6]], CARD_Z0, 0.8) });
  for (const [i, y] of [CARD_YC + CARD_W / 2 - 4, CARD_YC - CARD_W / 2 - 1].entries()) box(`holder.clip${i}`, { x: FX + CARD_T, y, w: 1.2, d: 5, r: 0.5 }, CARD_Z0 + CARD_HT - 6, 7.4, { tone: "mid" }, { steps: 2 });
}
const CELL = { x0: 7, y0: 14, pitch: 6.6, size: 5 };
const cellXY = (c) => [CELL.x0 + (c % 8) * CELL.pitch, CELL.y0 + Math.floor(c / 8) * CELL.pitch];
const CARD_FACE = planeMatrix(G.add3(G.add3(CARD_O, G.mul3(CARD_U, -CARD_W / 2)), G.mul3(CARD_V, CARD_HT)), CARD_U, G.mul3(CARD_V, -1));
{
  const rr = (x, y, w, h, r) => `M${f2(x + r)} ${f2(y)}H${f2(x + w - r)}A${r} ${r} 0 0 1 ${f2(x + w)} ${f2(y + r)}V${f2(y + h - r)}A${r} ${r} 0 0 1 ${f2(x + w - r)} ${f2(y + h)}H${f2(x + r)}A${r} ${r} 0 0 1 ${f2(x)} ${f2(y + h - r)}V${f2(y + r)}A${r} ${r} 0 0 1 ${f2(x + r)} ${f2(y)}Z`;
  let open = "";
  let punched = "";
  for (let c = 0; c < M.CASES; c++) {
    const [x, y] = cellXY(c);
    const d = rr(x, y, CELL.size, CELL.size, 0.7);
    if (M.expected[c]) punched += d;
    else open += d;
  }
  const header =
    `<path class="iso-line" data-tone="mid" data-free="" d="M7 4.6H34M7 7.8H24"/>` +
    `<path class="lf-hole" d="M${CARD_W - 7.4} 6a1.9 1.9 0 1 0 0.01 0Z"/>` +
    `<path class="iso-line" data-tone="mid" d="M${CARD_W - 7.4} 6a1.9 1.9 0 1 0 0.01 0Z"/>` +
    `<path class="iso-line" data-tone="lo" d="M0 11H${CARD_W}"/>`;
  const rowTicks = Array.from({ length: 8 }, (_, r) => `M3.2 ${f2(CELL.y0 + r * CELL.pitch + CELL.size / 2)}H5`).join("");
  const face =
    `<g transform="${CARD_FACE}">` +
    `<path class="lf-cardface" d="M0 0H${CARD_W}V${CARD_HT}H0Z"/>` +
    header +
    `<path class="iso-line" data-tone="lo" d="M3.2 11V${CARD_HT}"/>` +
    `<path class="iso-line" data-tone="mid" d="${rowTicks}"/>` +
    `<path class="iso-line" data-tone="lo" d="${open}"/>` +
    `<path class="lf-hole" d="${punched}"/><path class="iso-line" data-tone="mid" d="${punched}"/>` +
    `<path class="lf-mark iso-line" data-tone="hi" data-part="mark" d="${rr(-1.1, -1.1, CELL.size + 2.2, CELL.size + 2.2, 1.3)}" transform="translate(${CELL.x0} ${CELL.y0})"/>` +
    `</g>`;
  prism("card", CARD, [[-CARD_W / 2, 0], [CARD_W / 2, 0], [CARD_W / 2, CARD_HT], [-CARD_W / 2, CARD_HT]], -CARD_T, 0, { tone: "hi" }, { extra: face });
}

// ---------------------------------------------------------------- comparator with lamp and counter (front right)
const COMP = { x: 10, y: -48, w: 31, d: 38, r: 2.5 };
const COMP_H = 22;
const FACE_X = COMP.x + COMP.w;
const LAMP = [21, -26];
{
  const extra = screws([[COMP.x + 3.6, COMP.y + 3.6], [COMP.x + 3.6, COMP.y + COMP.d - 3.6], [COMP.x + COMP.w - 3.6, COMP.y + 3.6], [COMP.x + COMP.w - 3.6, COMP.y + COMP.d - 3.6]], COMP_H, 1.1);
  const vents = [0, 1, 2, 3].map((i) => path3([[COMP.x + 7.5 + i * 3.2, COMP.y + COMP.d, 6], [COMP.x + 8.5 + i * 3.2, COMP.y + COMP.d, 6], [COMP.x + 8.5 + i * 3.2, COMP.y + COMP.d, 14], [COMP.x + 7.5 + i * 3.2, COMP.y + COMP.d, 14]], true)).join("");
  box("comp", COMP, 0, COMP_H, { tone: "mid" }, { steps: 5, bevel: 0.8, extra, inner: Ln(k.sideSeam(COMP, COMP_H - 3.4, P, 5), { tone: "lo" }) + Ln(vents, { tone: "lo" }) });
}
cyl("lamp.collar", LAMP[0], LAMP[1], 6.8, COMP_H, 1.6, { tone: "mid" }, { steps: 40, owner: "lamp" });
cyl("lamp.bezel", LAMP[0], LAMP[1], 5.6, COMP_H + 1.6, 3, { tone: "mid" }, { steps: 40, owner: "lamp", extra: Ln(k.knurl(LAMP[0], LAMP[1], 5.6, COMP_H + 1.6, COMP_H + 4.6, 40, P, 0.3), { tone: "lo" }) });
{
  const LR = 4.7;
  const LH = 4.6;
  const z0 = COMP_H + 4.6;
  const radius = (s) => LR * Math.sqrt(Math.max(0, 1 - (s / LH) ** 2));
  const slope = (s) => {
    const q = Math.min(0.9995, s / LH);
    return (-LR * (q / LH)) / Math.sqrt(1 - q * q);
  };
  const profile = Array.from({ length: 25 }, (_, i) => [(i / 24) * LH * 0.985, radius((i / 24) * LH * 0.985), 1]);
  profile[0] = [0, LR];
  const F = G.frameOf([LAMP[0], LAMP[1], z0], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
  const paths = G.solidOf(profile, F, P, { smooth: { slope, radius } });
  const shape = record(A.solid(F, profile, { name: "lamp.lens", owner: "lamp", radius }));
  put("lamp.lens", [LAMP[0], LAMP[1], z0 + 2], `<g class="lf-lamp" data-part="lamp">${S(paths, { tone: "hi", crease: "none" })}</g>`, [shape]);
}
// counter window on the comparator's front face: local x runs toward -y, local y runs down
const CNT_O = [FACE_X, -13, 19];
const CNT_M = planeMatrix(CNT_O, [0, -1, 0], [0, 0, -1]);
const WIN = { x: 2, y: 2, w: 20, h: 11, r: 1.2 };
const DRUM = { pitch: 10, size: 8.2, tens: WIN.x + 5.2, units: WIN.x + 14.8, base: WIN.y + 8.4 };
const knobF = G.frameOf([FACE_X, -41.5, 8.5], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
{
  const ribs = G.ribsOf(knobF, 0.3, 3.2, 2.8, 30, P, { fade: [0.1, 0.55], seams: false });
  turned("comp.knob", knobF, [[0, 2.8], [3.2, 2.8]], { tone: "mid", inner: k.fadedSvg(ribs, { tone: "lo" }) }, { extra: Ln(G.circleOf(knobF, 3.2, 1.1, P, 20), { tone: "lo" }) });
}
// binding posts (test terminals) on the lid
for (const [i, y] of [-39, -44].entries()) {
  const x = 33;
  const ring6 = hexRing(x, y, 1.9, 0);
  const nut = record(A.extruded(ring6, COMP_H, 1.1, { name: `post${i}.nut` }));
  put(`post${i}.nut`, [x, y, COMP_H + 0.55], S(k.extrude(ring6, COMP_H, 1.1, P), { tone: "mid" }), [nut]);
  cyl(`post${i}.stem`, x, y, 0.9, COMP_H + 1.1, 1.5, { tone: "mid" }, { steps: 16 });
  cyl(`post${i}.cap`, x, y, 1.6, COMP_H + 2.6, 2.4, { tone: "mid" }, { steps: 22, extra: Ln(k.knurl(x, y, 1.6, COMP_H + 2.6, COMP_H + 5, 16, P, 0.25), { tone: "lo" }) + Ln(k.ring(x, y, 0.55, COMP_H + 5, P, 12), { tone: "lo" }) });
}

// ---------------------------------------------------------------- the coin chute on the back panel
// The chute is laid out on an old, smaller grid and mapped up: y and z both scale by CS.
const CS = 1.25;
const Yc = (o) => -101 + (o + 162) * CS;
const Zc = (o) => (o - 6) * CS;
const CR = 6.2; // coin radius
const CT = 1.8; // coin thickness
const CH = { x0: FX, x1: FX + 4.8, lip: 0.9, floor: 1.5, lipH: 1.8 };
const XC = (CH.x0 + CH.x1) / 2; // the coin's centre plane
const TH = 16 * deg;
const tn = Math.tan(TH);
const TRUNK = { y0: Yc(-76), y1: Yc(-110), z0: Zc(51) };
const trunkZ = (y) => TRUNK.z0 - (TRUNK.y0 - y) * tn;
const FLAP = { y0: TRUNK.y1, y1: Yc(-121) };
const RAILB = { y0: FLAP.y1, y1: Yc(-143) };
const STOPB = { y0: Yc(-156), y1: Yc(-154) };
const RAILA = { y0: Yc(-124), y1: Yc(-92), z0: Zc(30.5) };
const railAZ = (y) => RAILA.z0 - (y - RAILA.y0) * tn;
const STOPA = { y0: Yc(-81), y1: Yc(-79) };
const TRAY_W = 17;
const TRAY_B = { x: FX + 0.3, y: Yc(-162), w: TRAY_W, d: 20, r: 1 };
const TRAY_A = { x: FX + 0.3, y: Yc(-97), w: TRAY_W, d: 20, r: 1 };
const TRAY_FLOOR = 1;
function rail(name, ya, za, yb, zb) {
  const floor = [[ya, za], [yb, zb], [yb, zb - CH.floor], [ya, za - CH.floor]];
  board(`${name}.floor`, floor, CH.x0, CH.x1 + CH.lip, { tone: "mid" });
  const lip = [[ya, za], [yb, zb], [yb, zb + CH.lipH], [ya, za + CH.lipH]];
  board(`${name}.lip`, lip, CH.x1, CH.x1 + CH.lip, { tone: "hi" }, { bias: 0.4 });
}
rail("trunk", TRUNK.y0, trunkZ(TRUNK.y0), TRUNK.y1, trunkZ(TRUNK.y1));
rail("railB", RAILB.y0, trunkZ(RAILB.y0), RAILB.y1, trunkZ(RAILB.y1));
rail("railA", RAILA.y0, railAZ(RAILA.y0), RAILA.y1, railAZ(RAILA.y1));
board("trunk.end", [[TRUNK.y0 + 3.6, trunkZ(TRUNK.y0) - CH.floor], [TRUNK.y0, trunkZ(TRUNK.y0) - CH.floor], [TRUNK.y0, trunkZ(TRUNK.y0) + 13], [TRUNK.y0 + 3.6, trunkZ(TRUNK.y0) + 13]], CH.x0, CH.x1 + CH.lip, { tone: "mid" });
board("stopB", [[STOPB.y1, trunkZ(RAILB.y1) - 10], [STOPB.y0, trunkZ(RAILB.y1) - 10], [STOPB.y0, trunkZ(RAILB.y1) + 11], [STOPB.y1, trunkZ(RAILB.y1) + 11]], CH.x0, CH.x1 + CH.lip, { tone: "mid" });
board("stopA", [[STOPA.y1, railAZ(RAILA.y1) - 10], [STOPA.y0, railAZ(RAILA.y1) - 10], [STOPA.y0, railAZ(RAILA.y1) + 11], [STOPA.y1, railAZ(RAILA.y1) + 11]], CH.x0, CH.x1 + CH.lip, { tone: "mid" });
// flap: pivots about x at its -y end; "builder" bridges the gap, "buyer" hangs down as a wall
const FLAP_HANG = trunkZ(FLAP.y1) - (railAZ(FLAP.y1) + 1.2);
const FLAP_POSES = {
  builder: [[FLAP.y1, trunkZ(FLAP.y1)], [FLAP.y0, trunkZ(FLAP.y0)], [FLAP.y0, trunkZ(FLAP.y0) - CH.floor], [FLAP.y1, trunkZ(FLAP.y1) - CH.floor]],
  buyer: [[FLAP.y1 + CH.floor, trunkZ(FLAP.y1)], [FLAP.y1, trunkZ(FLAP.y1)], [FLAP.y1, trunkZ(FLAP.y1) - FLAP_HANG], [FLAP.y1 + CH.floor, trunkZ(FLAP.y1) - FLAP_HANG]],
};
{
  const shapes = Object.entries(FLAP_POSES).map(([pose, poly]) => record(A.prism(XF, poly, CH.x0, CH.x1, { name: `flap.${pose}`, owner: "flap" })));
  const svg = Object.entries(FLAP_POSES).map(([pose, poly]) => `<g class="lf-flap-${pose}">${S(G.prismOf(XF, poly, CH.x0, CH.x1, P), { tone: "hi" })}</g>`).join("");
  const pin = G.frameOf([CH.x0, FLAP.y1, trunkZ(FLAP.y1) - 0.75], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  put("flap", [CH.x0 + 1.5, FLAP.y1 + 3, trunkZ(FLAP.y1) - 3], `<g data-part="flap">${svg}</g>`, shapes);
  discOn("flap.pin", pin, CH.x1 + CH.lip - CH.x0, CH.x1 + CH.lip - CH.x0 + 0.8, 1.1, { tone: "mid" }, { owner: "flap" });
}
// the coin at rest, and the latch pin that holds it: a rod down out of a solenoid can
const nrm = [-Math.sin(TH), Math.cos(TH)]; // floor normal in (y, z)
const C0_BACK = TRUNK.y0 - 1.2; // the coin's uphill edge sits just clear of the end block
const C0 = [C0_BACK - CR, trunkZ(C0_BACK - CR + CR * Math.sin(TH)) + CR * Math.cos(TH)];
void nrm;
const PIN_R = 1.1;
const LATCH_Y = C0[0] - CR - PIN_R - 0.08;
const PIN_BOTTOM = trunkZ(LATCH_Y + PIN_R) + 0.5;
const CAN = { x: FX + 3.9, y: LATCH_Y, r: 3.6, z: C0[1] + CR + 6, h: 15 };
const PIN_LEN = CAN.z - PIN_BOTTOM;
const PIN_F = G.frameOf([XC, LATCH_Y, CAN.z], [0, 0, -1], [1, 0, 0], [0, 1, 0]);
const PIN = G.rodOut(PIN_F, 0, PIN_LEN, PIN_R, P, { stroke: 0 });
{
  const shape = record(A.slide(PIN_F, 0, PIN_LEN, PIN_R, { name: "latch.pin" }));
  put("latch.pin", [XC, LATCH_Y, CAN.z - PIN_LEN / 2], `<clipPath id="__ID__-pin"><path data-hold d="${PIN.clip}"/></clipPath><g data-part="pin"><g clip-path="url(#__ID__-pin)">${S(PIN.paths, { tone: "hi" })}</g></g>`, [shape], { bias: 0.6 });
}
{
  // the solenoid can: windings as faint rings, a gland nut at the bottom, a bracket arm on top
  const windings = [3, 5, 7, 9, 11].map((dz) => k.sideArc(CAN.x, CAN.y, CAN.r, CAN.z + dz, P, 28)).join("");
  cyl("solenoid", CAN.x, CAN.y, CAN.r, CAN.z + 1.2, CAN.h - 1.2, { tone: "hi", inner: Ln(windings, { tone: "lo" }) }, { steps: 40, bevel: 0.4, owner: "solenoid" });
  const ring6 = hexRing(CAN.x, CAN.y, 2.4, 0);
  const gland = record(A.extruded(ring6, CAN.z, 1.2, { name: "solenoid.gland", owner: "solenoid" }));
  put("solenoid.gland", [CAN.x, CAN.y, CAN.z + 0.6], S(k.extrude(ring6, CAN.z, 1.2, P), { tone: "mid" }), [gland]);
}
// the conduit: a square tube up the panel from the deck to an arm over the solenoid; the
// comparator's cable lands at its foot, so the decision visibly reaches the pin
const CONDUIT = { x: FX, y: TRUNK.y0 + 6, w: 4.2, d: 4.2, r: 0.6 };
const ARM_Z = CAN.z + CAN.h;
box("conduit", CONDUIT, 0, ARM_Z + 3.4, { tone: "mid" }, { steps: 2, extra: Dots([at([FX + 4.2, CONDUIT.y + 2.1, 10]), at([FX + 4.2, CONDUIT.y + 2.1, ARM_Z - 6])], { size: 0.5, tone: "mid" }) });
box("conduit.arm", { x: FX, y: CAN.y - 2.2, w: 6.4, d: CONDUIT.y - CAN.y + 2.2, r: 0.6 }, ARM_Z, 3.4, { tone: "mid" }, { steps: 2, owner: "solenoid" });
// the coin slot: a bezel over the place the coin waits
{
  const y0 = C0[0] - CR * 0.7;
  const y1 = Math.min(TRUNK.y0, C0[0] + CR + 1);
  const z0 = C0[1] + CR + 1.2;
  const z1 = z0 + 3.2;
  const top = path3([[FX + 1, y1 - 1.2, z1], [FX + 1, y0 + 1.2, z1], [FX + 3.4, y0 + 1.2, z1], [FX + 3.4, y1 - 1.2, z1]], true);
  board("slot", [[y1, z0], [y0, z0], [y0, z1], [y1, z1]], FX, FX + 5.2, { tone: "mid" }, { extra: Ln(top, { tone: "lo" }) });
}
// trays: floor, back, two sides, a low front; each with a glyph plaque on the deck in front of it
function tray(name, plan) {
  const t = 0.9;
  const hWall = 5;
  box(`${name}.floor`, plan, 0, TRAY_FLOOR, { tone: "lo" }, { steps: 2 });
  box(`${name}.left`, { x: plan.x, y: plan.y + plan.d - t, w: plan.w, d: t, r: 0.3 }, TRAY_FLOOR, hWall, { tone: "mid" }, { steps: 2 });
  box(`${name}.right`, { x: plan.x, y: plan.y, w: plan.w, d: t, r: 0.3 }, TRAY_FLOOR, hWall, { tone: "mid" }, { steps: 2 });
  box(`${name}.front`, { x: plan.x + plan.w - t, y: plan.y + t, w: t, d: plan.d - 2 * t, r: 0.3 }, TRAY_FLOOR, 2.6, { tone: "mid" }, { steps: 2, bias: 0.5 });
}
tray("trayB", TRAY_B);
tray("trayA", TRAY_A);
function plaque(name, cy, glyph) {
  const plan = { x: FX + TRAY_W + 3.4, y: cy - 7, w: 12, d: 14, r: 1.2 };
  const z = 0.8;
  let g = "";
  const cx = plan.x + plan.w / 2;
  if (glyph === "chip") {
    // a chip: a body with three legs each side and a notch
    g += k.planOutline({ x: cx - 2.6, y: cy - 4, w: 5.2, d: 8, r: 0.5 }, z, P, 2);
    for (const dy of [-2.4, 0, 2.4]) g += k.lineOnTop([cx - 2.6, cy + dy], [cx - 4.2, cy + dy], z, P) + k.lineOnTop([cx + 2.6, cy + dy], [cx + 4.2, cy + dy], z, P);
  } else {
    // the table card: a 3 x 3 grid of cells
    for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) g += k.planOutline({ x: cx - 4 + i * 2.8, y: cy - 4 + j * 2.8, w: 2.2, d: 2.2, r: 0.3 }, z, P, 1);
  }
  box(name, plan, 0, z, { tone: "lo", crease: "none" }, { extra: Ln(g, { tone: "hi" }) + Ln(k.planOutline(k.insetPlan(plan, 1), z, P, 3), { tone: "faint" }) });
}
plaque("plaqueB", TRAY_B.y + TRAY_B.d / 2, "chip");
plaque("plaqueA", TRAY_A.y + TRAY_A.d / 2, "card");

// ---------------------------------------------------------------- deadline clock (front right)
const CLOCK = [29, -76];
const CLOCK_R = 11;
const CLOCK_Z = 6;
const CLOCK_TOP = CLOCK_Z + 5;
const DEAD = 0.82; // the deadline mark, as a share of a turn
cyl("clock.post", CLOCK[0], CLOCK[1], 7.5, 0, CLOCK_Z, { tone: "mid" }, { steps: 36, bevel: 0.4 });
{
  const [x, y] = CLOCK;
  const t = k.radialTicks(x, y, CLOCK_R - 3.2, 60, 5, CLOCK_TOP, [1.2, 2.6], P);
  const deadA = DEAD * Math.PI * 2;
  const wedge = [0, 1, 2, 3, 4, 5, 6].map((i) => {
    const a = deadA + ((i - 3) / 3) * 0.06;
    return [x + Math.sin(a) * (CLOCK_R - 2.4), y - Math.cos(a) * (CLOCK_R - 2.4)];
  });
  const mark = k.onTop([[x + Math.sin(deadA) * (CLOCK_R - 7), y - Math.cos(deadA) * (CLOCK_R - 7)], ...wedge, [x + Math.sin(deadA) * (CLOCK_R - 7), y - Math.cos(deadA) * (CLOCK_R - 7)]], CLOCK_TOP, P);
  const extra =
    Ln(k.knurl(x, y, CLOCK_R, CLOCK_TOP - 2.4, CLOCK_TOP, 64, P, 0.3), { tone: "lo" }) +
    Ln(k.ring(x, y, CLOCK_R - 2.4, CLOCK_TOP, P, 64), { tone: "lo" }) +
    Ln(k.ring(x, y, 1.2, CLOCK_TOP, P, 16), { tone: "mid" }) +
    Ln(t.minor, { tone: "lo" }) +
    Ln(t.major, { tone: "mid" }) +
    `<path class="lf-dead" d="${mark}Z"/>` +
    Ln(mark, { tone: "hi" });
  cyl("clock", x, y, CLOCK_R, CLOCK_Z, 5, { tone: "hi", crease: "lo", inner: Ln(k.sideArc(x, y, CLOCK_R, CLOCK_TOP - 2.4, P, 40), { tone: "faint" }) }, { steps: 64, bevel: 0.6, extra });
}
const HAND = { r: CLOCK_R - 3.6, tail: 2.4, z: CLOCK_TOP + 0.2 };

// ---------------------------------------------------------------- cables
const CAB_R = 0.8;
const CAB_Z = CAB_R * 1.45 + 0.05; // the shells sit just clear of the deck
cable("cable.switches", [[34, BANK.y, CAB_Z], [34, SBASE.y + SBASE.d, CAB_Z]], CAB_R, { bend: 3 });
cable("cable.socket", [[4, SBASE.y, CAB_Z], [4, -30, CAB_Z], [COMP.x, -30, CAB_Z]], CAB_R);
cable("cable.latch", [[COMP.x, -42, CAB_Z], [-6, -42, CAB_Z], [-6, CONDUIT.y + 2.1, CAB_Z], [FX + CONDUIT.w, CONDUIT.y + 2.1, CAB_Z]], CAB_R);

// ---------------------------------------------------------------- settle the painter's order
A.settle(R, P);
R.items.sort((a, b) => a.key - b.key);
const indexOf = (name) => R.items.findIndex((item) => item.name === name);
const slots = new Map();
const after = (names, svg) => {
  const index = Math.max(...names.map(indexOf));
  slots.set(index, (slots.get(index) ?? "") + svg);
};
after(["panel", "trunk.floor", "railA.floor", "railB.floor", "flap", "trunk.end", "stopA", "stopB"], `<g data-part="coin-chute"></g>`);
after(["trayA.floor", "trayA.left", "trayA.right"], `<g data-part="coin-trayA"></g>`);
after(["trayB.floor", "trayB.left", "trayB.right"], `<g data-part="coin-trayB"></g>`);
const items = R.items.map((item, index) => `<g class="it" data-name="${item.name}"${item.attrs ?? ""}>${item.svg}</g>${slots.get(index) ?? ""}`);

// counter: drawn after the comparator box, in its face plane
const drumStrip = (cx) => {
  let text = "";
  for (let d = 0; d <= 10; d++) text += `<text class="lf-digit" x="${cx}" y="${f2(DRUM.base + d * DRUM.pitch)}" text-anchor="middle" font-size="${DRUM.size}">${d % 10}</text>`;
  return text;
};
const winRect = `M${WIN.x + WIN.r} ${WIN.y}H${WIN.x + WIN.w - WIN.r}A${WIN.r} ${WIN.r} 0 0 1 ${WIN.x + WIN.w} ${WIN.y + WIN.r}V${WIN.y + WIN.h - WIN.r}A${WIN.r} ${WIN.r} 0 0 1 ${WIN.x + WIN.w - WIN.r} ${WIN.y + WIN.h}H${WIN.x + WIN.r}A${WIN.r} ${WIN.r} 0 0 1 ${WIN.x} ${WIN.y + WIN.h - WIN.r}V${WIN.y + WIN.r}A${WIN.r} ${WIN.r} 0 0 1 ${WIN.x + WIN.r} ${WIN.y}Z`;
const counterSvg =
  `<g transform="${CNT_M}"><clipPath id="__ID__-win"><path d="${winRect}"/></clipPath>` +
  `<path class="lf-window" d="${winRect}"/>` +
  `<g clip-path="url(#__ID__-win)"><g data-part="drum-tens">${drumStrip(DRUM.tens)}</g><g data-part="drum-units">${drumStrip(DRUM.units)}</g>` +
  `<path class="iso-line" data-tone="lo" d="M${WIN.x + WIN.w / 2} ${WIN.y}V${WIN.y + WIN.h}"/>` +
  `<path class="lf-shadow" d="M${WIN.x} ${WIN.y}H${WIN.x + WIN.w}V${WIN.y + 1.6}H${WIN.x}Z"/></g>` +
  `<path class="iso-line" data-tone="lo" d="${winRect}"/>` +
  `<path class="iso-line" data-tone="faint" d="M${WIN.x - 1.6} ${WIN.y - 1.6}H${WIN.x + WIN.w + 1.6}V${WIN.y + WIN.h + 1.6}H${WIN.x - 1.6}Z"/>` +
  `</g>`;
{
  const index = indexOf("comp");
  slots.set(index, (slots.get(index) ?? "") + counterSvg);
}
const items2 = R.items.map((item, index) => `<g class="it" data-name="${item.name}"${item.attrs ?? ""}>${item.svg}</g>${slots.get(index) ?? ""}`);
void items;

// hit area and focus ring for the chip (drawn on top of everything)
const chipHull = (() => {
  const pts = [];
  for (const z of [ZIF_TOP, CHIP_TOP + 14]) for (const [x, y] of [[CHIP.x - 2, CHIP.y - 1], [CHIP.x + CHIP.w + 2, CHIP.y - 1], [CHIP.x + CHIP.w + 2, CHIP.y + CHIP.d + 1], [CHIP.x - 2, CHIP.y + CHIP.d + 1]]) pts.push(at([x, y, z]));
  return pts;
})();
const chipCentre = at([CHIP.x + CHIP.w / 2, CHIP.y + CHIP.d / 2, CHIP_TOP]);
const ring = (() => {
  const pts = [];
  for (const [x, y] of [[CHIP.x - 2.4, CHIP.y - 2], [CHIP.x + CHIP.w + 2.4, CHIP.y - 2], [CHIP.x + CHIP.w + 2.4, CHIP.y + CHIP.d + 2], [CHIP.x - 2.4, CHIP.y + CHIP.d + 2]]) for (const z of [ZIF_TOP - 0.4, CHIP_TOP + 1.2]) pts.push(at([x, y, z]));
  return G.hullOf(pts);
})();
const hitSvg =
  `<g class="lf-hit" data-part="hit" tabindex="0" role="button" focusable="true">` +
  `<path class="lf-hit-area" d="${k.pathOf(G.hullOf(chipHull), true)}"/>` +
  `<path class="lf-focus" d="${k.pathOf(ring, true)}"/>` +
  `</g>`;

const LABEL_TEXT = "An isometric drawing of an order test bench: six toggle switches, a chip in a test socket, the buyer's table card of 64 expected answers on the back panel, a comparator lamp with a case counter, a coin held by a solenoid latch pin at the top of a forked chute with a tray for the builder and a tray for the buyer, and a deadline clock.";
const svg = k.figureSvg({
  width: W,
  height: H,
  label: "__LABEL__",
  body: [...back, `<g class="lf-items">${items2.join("")}</g>`, `<g data-part="hand-layer"><path class="iso-line lf-hand" data-tone="hi" data-free="" data-part="hand" d=""/></g>`, hitSvg],
});

// ---------------------------------------------------------------- coin art and physics
const origin = at([0, 0, 0]);
const basis = { o: origin, x: G.sub3([...at([1, 0, 0]), 0], [...origin, 0]).slice(0, 2), y: G.sub3([...at([0, 1, 0]), 0], [...origin, 0]).slice(0, 2), z: G.sub3([...at([0, 0, 1]), 0], [...origin, 0]).slice(0, 2) };
const P0 = { ...P, origin: [0, 0] };
const coinFrame = (tip) => {
  // tip 0: standing, axis +x; tip 1: lying flat, axis +z (tipped toward the viewer)
  const a = [Math.cos((tip * Math.PI) / 2), 0, Math.sin((tip * Math.PI) / 2)];
  const u = [0, 1, 0];
  const v = G.cross3(a, u);
  return G.frameOf([0, 0, 0], a, u, v);
};
const TIPS = 10;
const coinArt = Array.from({ length: TIPS + 1 }, (_, i) => {
  const F = coinFrame(i / TIPS);
  const body = k.solidSvg(G.disc(-CT / 2, CT / 2, CR, F, P0, { steps: 44 }), { tone: "hi", lit: true });
  const facing = Math.abs(G.dot3(F.a, V));
  const face = G.dot3(F.a, V) >= 0 ? CT / 2 : -CT / 2;
  const ringLine = facing > 0.2 ? k.lineSvg(G.circleOf(F, face, CR - 0.55, P0, 36), { tone: "lo" }) : "";
  return body + ringLine;
});
// screen vectors of the standing coin's face, for the spin mark the page rebuilds each frame
const F0 = coinFrame(0);
const faceU = G.sub3([...k.iso(G.add3(G.mul3(F0.a, CT / 2), F0.u), P0), 0], [...k.iso(G.mul3(F0.a, CT / 2), P0), 0]).slice(0, 2);
const faceV = G.sub3([...k.iso(G.add3(G.mul3(F0.a, CT / 2), F0.v), P0), 0], [...k.iso(G.mul3(F0.a, CT / 2), P0), 0]).slice(0, 2);
const faceO = k.iso(G.mul3(F0.a, CT / 2), P0);

const COIN_GEOM = {
  g: 1962,
  r: CR,
  th: TH,
  start: C0,
  trunk: { y0: TRUNK.y0, y1: TRUNK.y1, z0: TRUNK.z0 },
  railB: { y1: RAILB.y1 },
  stopB: STOPB.y1,
  railA: { y0: RAILA.y0, y1: RAILA.y1, z0: RAILA.z0 },
  stopA: STOPA.y0,
  flapWall: FLAP.y1 + CH.floor,
  trayB: { y0: TRAY_B.y + 0.9, y1: TRAY_B.y + TRAY_B.d - 0.9, z: TRAY_FLOOR },
  trayA: { y0: TRAY_A.y + 0.9, y1: TRAY_A.y + TRAY_A.d - 0.9, z: TRAY_FLOOR },
  rimB: TRAY_FLOOR + 5,
  rimA: TRAY_FLOOR + 5,
  ct: CT,
  k: CS,
};
// the physics lives in the model so the page and this check run the same code
const pathB = M.coinFlight(COIN_GEOM, "builder");
const pathA = M.coinFlight(COIN_GEOM, "buyer");
for (const [name, path] of [["builder", pathB], ["buyer", pathA]]) {
  const end = path[path.length - 1];
  if (!(end.t <= M.T.travel)) throw new Error(`coin to the ${name} takes ${end.t.toFixed(2)} s, more than T.travel ${M.T.travel}`);
  if (!end.landed) throw new Error(`coin to the ${name} never lands`);
}

const DATA = {
  basis: { o: basis.o.map(f3), x: basis.x.map(f3), y: basis.y.map(f3), z: basis.z.map(f3) },
  xc: XC,
  cr: CR,
  ct: CT,
  tips: TIPS,
  face: { o: faceO.map(f3), u: faceU.map(f3), v: faceV.map(f3) },
  geom: COIN_GEOM,
  pinOut: PIN_LEN,
  pinAxis: [0, 0, 1],
  cell: { ...CELL },
  drum: { pitch: DRUM.pitch },
  clock: { x: CLOCK[0], y: CLOCK[1], r: HAND.r, tail: HAND.tail, z: HAND.z, dead: DEAD },
  lift: 14,
  wide: [0, 0, W, H],
  narrow: [88, 6, 432, 420], // a tighter frame on the mechanism for narrow hosts (the chassis ends are cropped)
  narrowBelow: 560,
};

// ---------------------------------------------------------------- CSS (scoped under .lathe-fig)
function scope(css, drop = null) {
  css = css.replace(/\/\*[\s\S]*?\*\//g, ""); // comments would glue onto the next selector
  const out = [];
  let i = 0;
  const read = () => {
    const start = i;
    let depth = 0;
    while (i < css.length) {
      const c = css[i];
      if (c === "{") depth++;
      if (c === "}") {
        depth--;
        if (depth === 0) {
          i++;
          break;
        }
      }
      i++;
    }
    return css.slice(start, i).trim();
  };
  while (i < css.length) {
    const block = read();
    if (!block) continue;
    const brace = block.indexOf("{");
    const head = block.slice(0, brace).trim();
    const body = block.slice(brace + 1, -1);
    if (head.startsWith("@keyframes")) out.push(block.replace(/@keyframes\s+([\w-]+)/, "@keyframes lf-$1"));
    else if (head.startsWith("@media")) {
      const inner = scope(body, drop);
      if (inner.trim()) out.push(`${head}{${inner}}`);
    } else if (drop && drop.test(head)) continue;
    else {
      const sel = head
        .split(",")
        .map((s) => s.trim())
        .map((s) => (s === ".iso" ? ".lathe-fig" : s.startsWith('.iso[data-theme="light"]') ? s.replace('.iso[data-theme="light"]', '.lathe-fig[data-theme="light"]') : s.startsWith(".lathe-fig") ? s : `.lathe-fig ${s}`))
        .join(",");
      out.push(`${sel}{${body.replace(/animation:\s*([\w-]+)/g, "animation:lf-$1")}}`);
    }
  }
  return out.join("\n");
}
const OWN_CSS = readFileSync(join(HERE, "figure.src.css"), "utf8");
const CSS = `/* Generated by web/figure/build.mjs. Do not edit; edit figure.src.css. Every selector is scoped under .lathe-fig. */\n${scope(k.ISO_CSS, /iso-plate|iso-figure/)}\n${scope(OWN_CSS)}\n`;

// ---------------------------------------------------------------- the module
const modelSource = readFileSync(join(HERE, "model.mjs"), "utf8").replace(/^export /gm, "");
const runtime = readFileSync(join(HERE, "runtime.js"), "utf8");
const STRINGS = {
  fig: "Fig 1",
  title: "Order test bench",
  hint: "Click the chip to swap in a faulty one",
  hintFaulty: "Click the chip to put the good one back",
  chipLabel: "Chip under test. Activate to swap between the good and the faulty chip.",
  rLocked: "Payment locked. Waiting for a chip.",
  rChecking: "Case {n} of 64: match",
  rRefused: "Case {n} of 64: wrong answer. Payment held.",
  rPaid: "64 of 64 match. Builder paid.",
  rRefunded: "Deadline passed. Buyer refunded.",
  kCard: "Table card: the buyer's 64 expected answers",
  kChip: "Chip: the builder's circuit",
  kLatch: "Latch: the contract. It opens only on 64 of 64.",
  caption: "The switches run every case. The lamp compares each answer with the card. One wrong answer and the coin stays where it is.",
};
const SWATCH = (mark) => {
  const body = mark === "flat" ? "M2 6.5 8 3.5 14 6.5 8 9.5Z" : "M2 4.5 8 1.5 14 4.5 14 6 8 9 2 6Z";
  const crease = mark === "flat" ? "" : `<path class="iso-swatch-crease" d="M2 4.5 8 7.5 14 4.5"/>`;
  return `<svg class="iso-swatch" data-mark="${mark}" viewBox="0 0 16 10" aria-hidden="true"><path d="${body}"/>${crease}</svg>`;
};
const MODULE = `// Generated by web/figure/build.mjs from model.mjs and runtime.js. Do not edit by hand.
// Order test bench: an isometric figure drawn with the Anatomy kit (MIT, see web/figure/kit/LICENSE).
// Usage: import { mountFigure } from "./figure.js"; link figure.css on the page.
${modelSource}
const DATA = ${JSON.stringify(DATA)};
const COIN_ART = ${JSON.stringify(coinArt)};
const SVG = ${JSON.stringify(svg)};
const LABEL = ${JSON.stringify(LABEL_TEXT)};
const SWATCHES = ${JSON.stringify({ lit: SWATCH("lit"), flat: SWATCH("flat"), raised: SWATCH("raised") })};
export const DEFAULT_STRINGS = Object.freeze(${JSON.stringify(STRINGS, null, 2)});
${runtime}
`;
for (const [name, text] of [["figure.js", MODULE], ["figure.css", CSS]]) {
  if (/[–—]/.test(text)) throw new Error(`${name} contains an en or em dash`);
}
// the page ships a Content-Security-Policy without 'unsafe-inline' styles
if (/style\s*=|setAttribute\(\s*["']style|<style|\.style\b|cssText/.test(MODULE)) throw new Error("figure.js sets an inline style; the page's Content-Security-Policy blocks it");
writeFileSync(join(WEB, "figure.js"), MODULE);
writeFileSync(join(WEB, "figure.css"), CSS);
const solids = R.solids.filter((s) => s.kind !== "tube").length;
console.log(`wrote web/figure.js (${(MODULE.length / 1024).toFixed(0)} KB) and web/figure.css (${(CSS.length / 1024).toFixed(1)} KB) · ${R.items.length} items · ${solids} recorded solids · ${CABLES.length} cables · scale ${KS.toFixed(3)}`);
console.log(`coin: builder ${pathB[pathB.length - 1].t.toFixed(2)} s, buyer ${pathA[pathA.length - 1].t.toFixed(2)} s (budget ${M.T.travel} s)`);

if (PREVIEW) {
  mkdirSync(PREVIEW, { recursive: true });
  for (const theme of ["dark", "light"]) {
    const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Order test bench</title><style>${CSS}\nhtml,body{margin:0}body{background:${theme === "light" ? "#f4f4f2" : "#0b0b0c"};font:14px/1.6 ui-sans-serif,system-ui,sans-serif}main{width:min(620px,100% - 32px);margin:48px auto}</style></head><body><main><div id="host"></div></main><script type="module">${MODULE.replace(/<\/(script)/gi, "<\\/$1")}\nwindow.__fig = mountFigure(document.getElementById("host"), { theme: "${theme}" });</script></body></html>`;
    writeFileSync(join(PREVIEW, theme === "light" ? "preview-light.html" : "preview.html"), page);
  }
  console.log("wrote previews to", PREVIEW);
}

A.auditOrExit(R, P, {});
