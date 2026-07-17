// Homemade SVG preview of ../speakeasy-map.excalidraw so the map can be
// proof-read as a PNG without opening Excalidraw. Pairs with make-repo-map.mjs.
// Run: node docs/render-map-preview.mjs   (writes docs/map-preview.svg)
// Then: npx sharp-cli -i docs/map-preview.svg -o docs/map-preview.png
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const IN = join(HERE, "..", "speakeasy-map.excalidraw");
const OUT = join(HERE, "map-preview.svg");

const doc = JSON.parse(readFileSync(IN, "utf8"));
const els = doc.elements.filter((e) => !e.isDeleted);

const FONTS = {
  1: "'Segoe UI', Arial, sans-serif",
  2: "'Segoe UI', Arial, sans-serif",
  3: "Consolas, 'Courier New', monospace",
};
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const dash = (e) => (e.strokeStyle === "dashed" ? ' stroke-dasharray="8 6"' : "");

// Canvas bounds with padding
let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
for (const e of els) {
  minX = Math.min(minX, e.x);
  minY = Math.min(minY, e.y);
  maxX = Math.max(maxX, e.x + (e.width || 0));
  maxY = Math.max(maxY, e.y + (e.height || 0));
}
const PAD = 30;
const W = Math.ceil(maxX - minX + PAD * 2);
const H = Math.ceil(maxY - minY + PAD * 2);
const ox = PAD - minX, oy = PAD - minY;

const parts = [];
parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`);
parts.push(`<rect x="0" y="0" width="${W}" height="${H}" fill="${doc.appState?.viewBackgroundColor || "#ffffff"}"/>`);

for (const e of els) {
  if (e.type === "rectangle") {
    const fill = !e.backgroundColor || e.backgroundColor === "transparent" ? "none" : e.backgroundColor;
    const rx = e.roundness ? 8 : 0;
    parts.push(`<rect x="${e.x + ox}" y="${e.y + oy}" width="${e.width}" height="${e.height}" rx="${rx}" fill="${fill}" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth || 1}"${dash(e)}/>`);
  } else if (e.type === "text") {
    const size = e.fontSize;
    const lh = (e.lineHeight || 1.3) * size;
    const family = FONTS[e.fontFamily] || FONTS[1];
    e.text.split("\n").forEach((line, i) => {
      const y = e.y + oy + i * lh + size * 0.85;
      parts.push(`<text x="${e.x + ox}" y="${y}" font-family="${family}" font-size="${size}" fill="${e.strokeColor}">${esc(line)}</text>`);
    });
  } else if (e.type === "line" || e.type === "arrow") {
    const pts = e.points.map(([px, py]) => [e.x + px + ox, e.y + py + oy]);
    const ptStr = pts.map((p) => p.join(",")).join(" ");
    parts.push(`<polyline points="${ptStr}" fill="none" stroke="${e.strokeColor}" stroke-width="${e.strokeWidth || 1}"${dash(e)}/>`);
    if (e.type === "arrow" && e.endArrowhead) {
      const [x1, y1] = pts[pts.length - 2];
      const [x2, y2] = pts[pts.length - 1];
      const ang = Math.atan2(y2 - y1, x2 - x1);
      const L = 12, Wd = 5;
      const ax = x2 - L * Math.cos(ang), ay = y2 - L * Math.sin(ang);
      const p1 = [ax - Wd * Math.sin(ang), ay + Wd * Math.cos(ang)];
      const p2 = [ax + Wd * Math.sin(ang), ay - Wd * Math.cos(ang)];
      parts.push(`<polygon points="${x2},${y2} ${p1.join(",")} ${p2.join(",")}" fill="${e.strokeColor}"/>`);
    }
  }
}
parts.push("</svg>");
writeFileSync(OUT, parts.join("\n"));
console.log("wrote", OUT, `(${W}x${H})`);
