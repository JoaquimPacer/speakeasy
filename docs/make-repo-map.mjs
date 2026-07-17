// Generates ../speakeasy-map.excalidraw (run: node docs/make-repo-map.mjs from repo root,
// or node make-repo-map.mjs from docs/). Follows Repos/.claude/diagram-guidelines.md:
// ink text only, white chips on arrow midpoints with line visible on both sides,
// edge-to-edge arrows, one accent color, legend for line styles.
// docs/REPO_MAP.md is the source of truth. Preview: node docs/render-map-preview.mjs
// then npx sharp-cli -i docs/map-preview.svg -o docs/map-preview.png
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "speakeasy-map.excalidraw");

const INK = "#1c1913";
const INK_SOFT = "#55503f";
const INK_MUTED = "#6f6a59";
const ACCENT = "#7a4a21";

let n = 1000;
const el = (props) => ({
  id: "el" + n++,
  angle: 0,
  strokeColor: INK,
  backgroundColor: "transparent",
  fillStyle: "solid",
  strokeWidth: 1,
  strokeStyle: "solid",
  roughness: 1,
  opacity: 100,
  groupIds: [],
  frameId: null,
  roundness: { type: 3 },
  seed: n * 7919,
  version: 1,
  versionNonce: n * 104729,
  isDeleted: false,
  boundElements: null,
  updated: 1,
  link: null,
  locked: false,
  ...props,
});

const els = [];

const text = (x, y, str, size, color, family = 1) =>
  els.push(el({ type: "text", x, y, width: str.length * size * 0.62, height: size * 1.3, text: str, fontSize: size, fontFamily: family, textAlign: "left", verticalAlign: "top", baseline: size, containerId: null, originalText: str, lineHeight: 1.3, strokeColor: color, roundness: null }));

function zone(x, y, w, h, label, color) {
  els.push(el({ type: "rectangle", x, y, width: w, height: h, backgroundColor: color, strokeColor: "#8a8471", strokeStyle: "dashed", roughness: 0 }));
  text(x + 14, y + 10, label, 14, INK_MUTED, 3);
}

function box(x, y, w, h, title, sub, bg = "#ffffff", titleColor = INK, subColor = INK_SOFT, stroke = INK) {
  els.push(el({ type: "rectangle", x, y, width: w, height: h, backgroundColor: bg, strokeColor: stroke, roughness: 1 }));
  text(x + 12, y + 10, title, 15, titleColor);
  if (sub) {
    els.push(el({ type: "text", x: x + 12, y: y + 34, width: w - 24, height: h - 42, text: sub, fontSize: 12, fontFamily: 1, textAlign: "left", verticalAlign: "top", baseline: 12, containerId: null, originalText: sub, lineHeight: 1.3, strokeColor: subColor, roundness: null }));
  }
}

// Labels longer than 9 chars wrap to two lines at a space/hyphen so the chip
// never eats its arrow. Shared by chip() (drawing) and the arrow() guard.
function chipDims(label) {
  let lines = [label];
  if (label.length > 9) {
    const mid = Math.floor(label.length / 2);
    let best = -1;
    for (let i = 0; i < label.length; i++) {
      if (label[i] === " " || label[i] === "-") {
        if (best === -1 || Math.abs(i - mid) < Math.abs(best - mid)) best = i;
      }
    }
    if (best !== -1) {
      lines = [label.slice(0, best + (label[best] === "-" ? 1 : 0)).trim(), label.slice(best + 1).trim()];
    }
  }
  const wText = Math.max(...lines.map((l) => l.length)) * 7.2;
  return { lines, w: wText + 16, h: lines.length === 2 ? 34 : 20 };
}

// White chip with ink text centered on (cx, cy).
function chip(cx, cy, label) {
  const { lines, w, h } = chipDims(label);
  els.push(el({ type: "rectangle", x: cx - w / 2, y: cy - h / 2, width: w, height: h, backgroundColor: "#ffffff", strokeColor: "#c9c3b4", strokeWidth: 1, roughness: 0, roundness: { type: 3 } }));
  lines.forEach((ln, i) => {
    els.push(el({ type: "text", x: cx - (ln.length * 7.2) / 2, y: cy - h / 2 + 4 + i * 14, width: ln.length * 7.2, height: 14, text: ln, fontSize: 11, fontFamily: 3, textAlign: "left", verticalAlign: "top", baseline: 11, containerId: null, originalText: ln, lineHeight: 1.25, strokeColor: INK, roundness: null }));
  });
}

// Guard (diagram-guidelines rule 3): a chip must sit on a straight, axis-aligned
// segment and cover at most half of it, so line stays visible on both sides.
// Fails the whole generation loudly rather than emitting a jammed label.
function guardChip(pts, label, lx, ly) {
  const { w, h } = chipDims(label);
  let seg = null, best = Infinity;
  for (let i = 0; i < pts.length - 1; i++) {
    const [ax, ay] = pts[i], [bx, by] = pts[i + 1];
    const d = Math.hypot((ax + bx) / 2 - lx, (ay + by) / 2 - ly);
    if (d < best) { best = d; seg = [[ax, ay], [bx, by]]; }
  }
  const [[ax, ay], [bx, by]] = seg;
  const horizontal = ay === by, vertical = ax === bx;
  if (!horizontal && !vertical) {
    console.error(`FAIL: chip "${label}" sits on a diagonal segment (${ax},${ay})->(${bx},${by}); straighten the arrow under the chip.`);
    process.exit(1);
  }
  const segLen = horizontal ? Math.abs(bx - ax) : Math.abs(by - ay);
  const extent = horizontal ? w : h;
  if (extent > segLen / 2) {
    console.error(`FAIL: chip "${label}" (${Math.ceil(extent)}px) covers more than half of its ${segLen}px segment; lengthen the arrow to at least ${Math.ceil(extent * 2)}px (move the boxes apart).`);
    process.exit(1);
  }
}

// Arrow through absolute waypoints; chip at chipAt (defaults to path midpoint).
function arrow(pts, label, dashed = false, chipAt = null) {
  const [x0, y0] = pts[0];
  const rel = pts.map(([x, y]) => [x - x0, y - y0]);
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  els.push(el({ type: "arrow", x: x0, y: y0, width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys), points: rel, startBinding: null, endBinding: null, startArrowhead: null, endArrowhead: "arrow", strokeColor: ACCENT, strokeWidth: 2, strokeStyle: dashed ? "dashed" : "solid", roundness: { type: 2 } }));
  if (label) {
    const [lx, ly] = chipAt ?? [(pts[0][0] + pts[pts.length - 1][0]) / 2, (pts[0][1] + pts[pts.length - 1][1]) / 2];
    guardChip(pts, label, lx, ly);
    chip(lx, ly, label);
  }
}

// ── Title + legend ────────────────────────────────────────────────────────────
text(40, 20, "speakeasy (Kithra): the spec repo behind the app", 24, INK);
text(40, 54, "verified 2026-07-16 · text twin that stays current: docs/REPO_MAP.md", 12, INK_MUTED, 3);
els.push(el({ type: "line", x: 760, y: 40, width: 40, height: 0, points: [[0, 0], [40, 0]], strokeColor: ACCENT, strokeWidth: 2, roundness: null }));
text(808, 32, "how the app gets made", 12, INK_SOFT);
els.push(el({ type: "line", x: 990, y: 40, width: 40, height: 0, points: [[0, 0], [40, 0]], strokeColor: ACCENT, strokeWidth: 2, strokeStyle: "dashed", roundness: null }));
text(1038, 32, "runtime path (E2E)", 12, INK_SOFT);

// ── Zones ─────────────────────────────────────────────────────────────────────
zone(40, 90, 300, 340, "THE PAPER (THIS REPO)", "#f4f0e8");
zone(430, 90, 260, 340, "THE BUILD", "#eef1f6");
zone(780, 90, 320, 340, "WHAT PEOPLE GET", "#f1ece5");
zone(40, 480, 1060, 190, "REFERENCE", "#f2efe9");

// ── Boxes ─────────────────────────────────────────────────────────────────────
box(60, 140, 260, 100, "README.md", "the public pitch: the\ncomparison table nobody\nelse can fill");
box(60, 290, 260, 110, "docs/", "SPEC (MVP), ARCHITECTURE\n(Go relay + Swift app),\nSECURITY (crypto model)");

box(450, 190, 220, 120, "Kithra build (Mac)", "coded from these docs\nwith Codex; lands here\nwhen ready");

box(805, 140, 270, 110, "Kithra iOS app", "Swift + libsodium; encrypts\non the device; App Store\nsubmit due Jul 24", "#7a4a21", "#ffffff", "#f0e6db", "#7a4a21");
box(805, 330, 270, 80, "Go relay server", "self-hosted dumb relay;\nsees only sealed blobs");

box(70, 525, 240, 110, "LICENSE + .gitignore", "MIT; secrets/ stays local\n(git exclude), never staged");
box(350, 525, 240, 110, "archive/", "CODEOWNERS from the collab\nera; Joshua moved on 2026-07");
box(630, 525, 250, 110, "this file", "speakeasy-map.excalidraw;\nregenerate via docs/\nmake-repo-map.mjs");

// ── Arrows (edge to edge; labeled segments straight, axis-aligned, 2x chip) ──
arrow([[320, 300], [450, 300]], "guides");                 // docs/ -> build (130px)
arrow([[670, 220], [805, 220]], "builds");                 // build -> app (135px)
arrow([[940, 250], [940, 330]], "sealed blobs", true);     // app -> relay (80px vertical, dashed)

const doc = {
  type: "excalidraw",
  version: 2,
  source: "speakeasy-repo-map",
  elements: els,
  appState: { gridSize: null, viewBackgroundColor: "#ffffff" },
  files: {},
};
writeFileSync(OUT, JSON.stringify(doc, null, 1));
console.log("wrote", OUT, "with", els.length, "elements");
