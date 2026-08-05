// Generates ../speakeasy-map.excalidraw (run: node docs/make-repo-map.mjs from repo root,
// or node make-repo-map.mjs from docs/). The layout rules are kept here so the
// map can be regenerated without relying on files outside this repository:
// ink text, white chips on arrow midpoints, edge-to-edge arrows, one accent.
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
text(40, 20, "speakeasy / Kithra: implemented repository map", 24, INK);
text(40, 54, "verified 2026-08-04 · text source: docs/REPO_MAP.md", 12, INK_MUTED, 3);
els.push(el({ type: "line", x: 860, y: 40, width: 40, height: 0, points: [[0, 0], [40, 0]], strokeColor: ACCENT, strokeWidth: 2, roundness: null }));
text(908, 32, "ciphertext runtime path", 12, INK_SOFT);

// ── Zones ─────────────────────────────────────────────────────────────────────
zone(40, 90, 330, 470, "IMPLEMENTED SOURCE", "#f4f0e8");
zone(420, 90, 800, 470, "RUNTIME + RELEASE STATE", "#eef1f6");
zone(40, 600, 1180, 150, "REFERENCE + LIMITS", "#f2efe9");

// ── Boxes ─────────────────────────────────────────────────────────────────────
box(60, 135, 290, 80, "server/", "Go + SQLite relay; local\nfilesystem ciphertext blobs");
box(60, 235, 290, 90, "ios/", "Native Swift/SwiftUI iPhone\napp + XCTest + Fastlane");
box(60, 345, 290, 80, "deploy/", "Docker Compose relay and\npublic support-site assets");
box(60, 445, 290, 90, "docs/ + testdata/", "API/security/release docs;\nshared protocol fixed vectors");

box(445, 160, 200, 130, "Sender iPhone", "record + encrypt locally;\nfresh content key for\neach video", "#7a4a21", "#ffffff", "#f0e6db", "#7a4a21");
box(750, 175, 180, 100, "Go relay", "store + route\nciphertext; sees\nrouting metadata");
box(1035, 160, 160, 130, "Recipient iPhone", "verify signed\nenvelope; decrypt\nlocally", "#7a4a21", "#ffffff", "#f0e6db", "#7a4a21");

box(445, 350, 350, 130, "Contact verification", "60-digit safety number or signed QR;\npins device keys before authenticated\nmessage exchange");
box(835, 350, 360, 130, "Pre-submission", "No public App Store URL; not in review.\nInternal TestFlight is only for the exact\nrelease-candidate smoke test.");

box(70, 635, 330, 85, "Fresh content keys", "Reduce single-key blast radius;\nnot Signal-style forward secrecy.");
box(445, 635, 330, 85, "Self-hosting boundary", "The Go relay is self-hostable;\nthe native iPhone app is not web-hosted.");
box(820, 635, 360, 85, "Other repository lanes", "GitHub Actions + Android scaffold +\nunpublished marketing drafts.");

// ── Arrows (edge to edge; labeled segments straight, axis-aligned, 2x chip) ──
arrow([[645, 225], [750, 225]], "blob");
arrow([[930, 225], [1035, 225]], "blob");

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
