// Prints the measured contrast matrix for the design system.
//
//   node scripts/contrast-matrix.mjs > docs/color-contrast-matrix.md
//
// Deliberately shares its measurement code shape with tests/color-contrast
// .test.mjs rather than importing from it: the test is the gate and must stay
// self-contained, this is the report. If the two ever disagree, the test wins.

import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

function parseColor(value) {
  const text = value.trim();
  const hex = text.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const body = hex[1].length === 3 ? [...hex[1]].map((c) => c + c).join("") : hex[1];
    return { r: parseInt(body.slice(0, 2), 16), g: parseInt(body.slice(2, 4), 16), b: parseInt(body.slice(4, 6), 16), a: 1 };
  }
  const rgba = text.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i);
  if (rgba) return { r: +rgba[1], g: +rgba[2], b: +rgba[3], a: rgba[4] === undefined ? 1 : +rgba[4] };
  throw new Error(`cannot parse colour: ${value}`);
}

const composite = (top, bottom) => top.a >= 1 ? top : {
  r: top.r * top.a + bottom.r * (1 - top.a),
  g: top.g * top.a + bottom.g * (1 - top.a),
  b: top.b * top.a + bottom.b * (1 - top.a),
  a: 1,
};

function luminance({ r, g, b }) {
  const channel = (value) => {
    const c = value / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(foreground, background) {
  const [light, dark] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (light + 0.05) / (dark + 0.05);
}

function readTokens(css, selector) {
  const start = css.indexOf(selector);
  const open = css.indexOf("{", start);
  let depth = 0;
  let end = open;
  for (let index = open; index < css.length; index += 1) {
    if (css[index] === "{") depth += 1;
    if (css[index] === "}") { depth -= 1; if (!depth) { end = index; break; } }
  }
  const body = css.slice(open + 1, end).replace(/\/\*[\s\S]*?\*\//g, "");
  const tokens = new Map();
  for (const match of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/gi)) tokens.set(match[1], match[2].trim());
  return tokens;
}

function resolve(tokens, name) {
  const value = tokens.get(name);
  const reference = value?.match(/^var\((--[a-z0-9-]+)\)$/i);
  return reference ? resolve(tokens, reference[1]) : parseColor(value);
}

const css = await read("../app/design-system.css");
const aliases = readTokens(await read("../app/workspace.css"), ":root {");
const light = new Map([...readTokens(css, ":root {"), ...aliases]);
const dark = new Map([...light, ...readTokens(css, ':root[data-theme="dark"]')]);

const hex = ({ r, g, b }) => "#" + [r, g, b].map((c) => Math.round(c).toString(16).padStart(2, "0")).join("");

function row(tokens, foreground, background, state, gate) {
  const bg = composite(resolve(tokens, background), resolve(tokens, "--canvas"));
  const fg = composite(resolve(tokens, foreground), bg);
  const measured = contrast(fg, bg);
  return { foreground, background, fgHex: hex(fg), bgHex: hex(bg), ratio: measured, state, gate, pass: measured >= gate };
}

const neutral = ["--canvas", "--surface", "--surface-raised", "--surface-sunken", "--surface-hover", "--surface-active", "--surface-selected", "--surface-selected-hover"];
const mutedOk = ["--canvas", "--surface", "--surface-raised", "--surface-sunken", "--surface-hover"];
const stateOf = { "--surface-hover": "hover", "--surface-active": "pressed", "--surface-selected": "selected", "--surface-selected-hover": "selected + hover" };

function matrix(tokens) {
  const rows = [];
  for (const role of ["--text-primary", "--text-secondary", "--accent-text"]) {
    for (const surface of neutral) rows.push(row(tokens, role, surface, stateOf[surface] ?? "default", 4.5));
  }
  for (const surface of mutedOk) rows.push(row(tokens, "--text-tertiary", surface, stateOf[surface] ?? "default", 4.5));
  for (const surface of neutral) rows.push(row(tokens, "--border-control", surface, "control boundary", 3));
  for (const surface of neutral) rows.push(row(tokens, "--focus-color", surface, "focus-visible", 3));
  for (const fill of ["--accent", "--accent-hover", "--accent-pressed"]) rows.push(row(tokens, "--on-accent", fill, "primary button", 4.5));
  for (const fill of ["--danger-solid", "--danger-solid-hover", "--danger-solid-pressed"]) rows.push(row(tokens, "--on-danger", fill, "destructive button", 4.5));
  for (const status of ["success", "warning", "danger", "info"]) rows.push(row(tokens, `--${status}`, `--${status}-soft`, "status badge", 4.5));
  for (let tone = 1; tone <= 6; tone += 1) rows.push(row(tokens, `--identity-${tone}-text`, `--identity-${tone}-soft`, "identity tone", 4.5));
  rows.push(row(tokens, "--text-disabled", "--surface-disabled", "disabled", 3));
  return rows;
}

const out = [];
out.push("# Colour contrast matrix");
out.push("");
out.push("Generated by `node scripts/contrast-matrix.mjs`. Every ratio is computed from");
out.push("the tokens in `app/design-system.css` as the browser resolves them - `var()`");
out.push("chains followed, translucent values composited over the canvas. The gates are");
out.push("enforced by `tests/color-contrast.test.mjs`; this file is the readable form.");
out.push("");
out.push("Gate 4.5:1 is WCAG 2.2 AA for normal text (1.4.3). Gate 3:1 is non-text");
out.push("contrast (1.4.11) for control boundaries and focus indicators. The disabled row");
out.push("is a **product** target - WCAG exempts inactive controls.");
out.push("");

for (const [name, tokens] of [["Light", light], ["Dark", dark]]) {
  const rows = matrix(tokens);
  const failures = rows.filter((entry) => !entry.pass);
  out.push(`## ${name}`);
  out.push("");
  out.push(`${rows.length} pairs, ${failures.length} failing.`);
  out.push("");
  out.push("| Foreground | Rendered bg | State | Ratio | Gate | |");
  out.push("|---|---|---|---:|---:|---|");
  for (const entry of rows) {
    out.push(`| \`${entry.foreground}\` ${entry.fgHex} | \`${entry.background}\` ${entry.bgHex} | ${entry.state} | ${entry.ratio.toFixed(2)}:1 | ${entry.gate}:1 | ${entry.pass ? "pass" : "**FAIL**"} |`);
  }
  out.push("");
}

console.log(out.join("\n"));
