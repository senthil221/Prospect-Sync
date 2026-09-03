import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// The contrast gate.
//
// This does not test a palette object copied out of a design document - that
// proves the document is self-consistent and nothing about the product. It
// parses app/design-system.css, resolves the var() chains the way the browser
// would, composites the translucent values over the backdrop they actually sit
// on, and measures. A value edited in that file without a matching measurement
// fails here.
//
// Gates (WCAG 2.2): 4.5:1 normal text including placeholders and tooltips,
// 3:1 for essential control boundaries, icons and state indicators. The one
// exception is marked: genuinely inactive controls are held to a 3:1 product
// target, which is a readability choice, not a WCAG requirement.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

/* ---------------------------------------------------------------- colour ---- */

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

/** Source-over compositing, which is what the browser does with an alpha fill. */
function composite(top, bottom) {
  if (top.a >= 1) return top;
  return {
    r: top.r * top.a + bottom.r * (1 - top.a),
    g: top.g * top.a + bottom.g * (1 - top.a),
    b: top.b * top.a + bottom.b * (1 - top.a),
    a: 1,
  };
}

function relativeLuminance({ r, g, b }) {
  const channel = (value) => {
    const c = value / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

function contrast(foreground, background) {
  const a = relativeLuminance(foreground);
  const b = relativeLuminance(background);
  const [light, dark] = a > b ? [a, b] : [b, a];
  return (light + 0.05) / (dark + 0.05);
}

/* ----------------------------------------------------------------- tokens ---- */

/**
 * Reads one theme's token table out of design-system.css.
 *
 * Light is `:root { ... }`; dark is the explicit `[data-theme="dark"]` block,
 * layered over light so a token the dark block does not redefine falls through
 * exactly as the cascade makes it.
 */
function readTokens(css, selector) {
  const start = css.indexOf(selector);
  assert.notEqual(start, -1, `${selector} must exist in design-system.css`);
  const open = css.indexOf("{", start);
  let depth = 0;
  let end = open;
  for (let index = open; index < css.length; index += 1) {
    if (css[index] === "{") depth += 1;
    if (css[index] === "}") { depth -= 1; if (!depth) { end = index; break; } }
  }
  // Comments are stripped before the declarations are read, not after: this
  // file explains its tokens in prose that mentions token names followed by a
  // colon, and a naive scan happily parses "--text-inverse: that means..." out
  // of a paragraph.
  const body = css.slice(open + 1, end).replace(/\/\*[\s\S]*?\*\//g, "");
  const tokens = new Map();
  for (const match of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/gi)) tokens.set(match[1], match[2].trim());
  return tokens;
}

function resolve(tokens, name, seen = new Set()) {
  assert.ok(tokens.has(name), `token ${name} is not defined`);
  assert.ok(!seen.has(name), `token ${name} resolves in a cycle`);
  seen.add(name);
  const value = tokens.get(name);
  const reference = value.match(/^var\((--[a-z0-9-]+)\)$/i);
  return reference ? resolve(tokens, reference[1], seen) : parseColor(value);
}

const css = await read("../app/design-system.css");
const workspaceCss = await read("../app/workspace.css");
// workspace.css keeps a block of legacy --ph-* aliases pointing at the semantic
// roles. They have to be resolvable here or the cascade scan silently skips
// every rule that uses one - which is exactly where the solid destructive
// button was hiding a --text-inverse-on-danger pair.
const aliases = readTokens(workspaceCss, ":root {");
const light = new Map([...readTokens(css, ":root {"), ...aliases]);
const darkOverrides = readTokens(css, ':root[data-theme="dark"]');
const dark = new Map([...light, ...darkOverrides]);
const themes = { light, dark };

/** Foreground over background, both by token name, alpha composited. */
function ratio(tokens, foreground, background, backdrop = "--canvas") {
  const under = resolve(tokens, backdrop);
  const bg = composite(resolve(tokens, background), under);
  const fg = composite(resolve(tokens, foreground), bg);
  return contrast(fg, bg);
}

const round = (value) => Math.round(value * 1000) / 1000;

/* ------------------------------------------------------------------ gates ---- */

// The surfaces a given text role is ALLOWED to sit on. This is the rule the
// prompt states in prose, encoded: muted text is fine on the canvas, on a card,
// on a raised surface, in a field and on a neutral hover - and nowhere else,
// because pressed and selected are where it stopped clearing 4.5:1.
const neutralSurfaces = ["--canvas", "--surface", "--surface-raised", "--surface-sunken", "--surface-hover", "--surface-active", "--surface-selected", "--surface-selected-hover"];
const mutedSurfaces = ["--canvas", "--surface", "--surface-raised", "--surface-sunken", "--surface-hover"];

for (const [name, tokens] of Object.entries(themes)) {
  test(`${name}: primary, secondary and link text clear 4.5:1 on every surface they may use`, () => {
    for (const role of ["--text-primary", "--text-secondary", "--accent-text"]) {
      for (const surface of neutralSurfaces) {
        const measured = ratio(tokens, role, surface);
        assert.ok(measured >= 4.5, `${role} on ${surface} is ${round(measured)}:1, below 4.5`);
      }
    }
  });

  test(`${name}: muted text clears 4.5:1 on the five surfaces it is permitted on`, () => {
    for (const surface of mutedSurfaces) {
      const measured = ratio(tokens, "--text-tertiary", surface);
      assert.ok(measured >= 4.5, `--text-tertiary on ${surface} is ${round(measured)}:1, below 4.5`);
    }
    // And the reason the other three are excluded: this is the pairing the
    // rule exists to prevent, kept measurable so the rule stays honest rather
    // than becoming folklore.
    for (const surface of ["--surface-active", "--surface-selected", "--surface-selected-hover"]) {
      const measured = ratio(tokens, "--text-tertiary", surface);
      assert.ok(measured < 6, `${surface} now clears comfortably (${round(measured)}:1) - revisit whether muted is still worth excluding`);
    }
  });

  test(`${name}: a control boundary is visible against the field AND the surface behind it`, () => {
    // 3:1 non-text contrast. Measuring only against the field is how a border
    // that is invisible on the card it sits in passes a review.
    for (const surface of neutralSurfaces) {
      const measured = ratio(tokens, "--border-control", surface);
      assert.ok(measured >= 3, `--border-control on ${surface} is ${round(measured)}:1, below 3`);
    }
    // A decorative divider is explicitly NOT held to this - darkening it would
    // make the product louder for no accessibility gain.
    const subtle = ratio(tokens, "--border-subtle", "--surface");
    assert.ok(subtle < 3, "if the subtle divider now clears 3:1 it has stopped being subtle");
  });

  test(`${name}: the focus ring is opaque and visible wherever it lands`, () => {
    // The ring is drawn OUTSIDE the control, so the colour adjacent to it is
    // the surface the control sits on - never the control's own fill.
    for (const surface of neutralSurfaces) {
      const measured = ratio(tokens, "--focus-color", surface);
      assert.ok(measured >= 3, `--focus-color on ${surface} is ${round(measured)}:1, below 3`);
    }

    // On a solid accent button the ring and the fill are the same hue family,
    // and measured against each other they are 1:1 in light mode - which is
    // exactly why the 2px gap exists. The gap is painted in the surface behind,
    // so the pair that has to clear 3:1 is that surface against the fill. If
    // the offset is ever removed, the ring vanishes into the one control people
    // reach for most and nothing else in this file would notice.
    assert.match(css, /outline-offset: 2px/);
    for (const fill of ["--accent", "--danger-solid"]) {
      for (const surface of ["--surface", "--canvas"]) {
        const gap = ratio(tokens, surface, fill);
        assert.ok(gap >= 3, `the focus gap on ${fill} shows ${surface} at ${round(gap)}:1, below 3`);
      }
    }
    assert.equal(resolve(tokens, "--focus-color").a, 1, "a translucent glow is not a focus indicator");
  });

  test(`${name}: white on every solid fill clears 4.5:1`, () => {
    for (const fill of ["--accent", "--accent-hover", "--accent-pressed"]) {
      const measured = ratio(tokens, "--on-accent", fill);
      assert.ok(measured >= 4.5, `--on-accent on ${fill} is ${round(measured)}:1, below 4.5`);
    }
    for (const fill of ["--danger-solid", "--danger-solid-hover", "--danger-solid-pressed"]) {
      const measured = ratio(tokens, "--on-danger", fill);
      assert.ok(measured >= 4.5, `--on-danger on ${fill} is ${round(measured)}:1, below 4.5`);
    }
  });

  test(`${name}: every status badge reads against its own soft background`, () => {
    for (const status of ["success", "warning", "danger", "info"]) {
      const measured = ratio(tokens, `--${status}`, `--${status}-soft`);
      assert.ok(measured >= 4.5, `--${status} on --${status}-soft is ${round(measured)}:1, below 4.5`);
    }
    // A status foreground is not a fill: this is the mistake the separate
    // --danger-solid ramp exists to prevent, and in dark it is dramatic.
    const asFill = ratio(tokens, "--on-danger", "--danger");
    if (name === "dark") assert.ok(asFill < 4.5, "the dark danger pastel must stay unusable as a solid fill, or the split is pointless");
  });

  test(`${name}: a disabled control is legible without looking enabled`, () => {
    // 3:1 is a product readability target, not a WCAG requirement - disabled
    // controls are exempt. It is asserted anyway because "disabled" was being
    // done with opacity, which produced ratios nobody had measured.
    const measured = ratio(tokens, "--text-disabled", "--surface-disabled");
    assert.ok(measured >= 3, `--text-disabled on --surface-disabled is ${round(measured)}:1, below the 3:1 product target`);
    // And it must not be mistakable for ordinary muted metadata.
    const muted = ratio(tokens, "--text-tertiary", "--surface");
    assert.ok(muted > ratio(tokens, "--text-disabled", "--surface"), "disabled text must be quieter than muted text");
  });

  test(`${name}: the overlay actually dims what is behind it`, () => {
    const overlay = resolve(tokens, "--overlay");
    assert.ok(overlay.a >= 0.4, `--overlay at ${overlay.a} is too transparent to separate a dialog from the page`);
    // The modal itself sits on the raised surface, so its text is measured
    // against that, not against the dimmed page.
    const measured = ratio(tokens, "--text-primary", "--surface-raised");
    assert.ok(measured >= 4.5, `dialog text is ${round(measured)}:1`);
  });
}

/* ------------------------------------------------------- the cascade itself -- */

test("no rule paints text and background with the same token", async () => {
  // The general form of the Boolean Apply bug: one token for both, a 1:1
  // ratio, an invisible label.
  const styles = (await read("../app/workspace.css")) + (await read("../app/components.css"));
  for (const rule of styles.match(/\{[^}]*\}/g) ?? []) {
    const background = rule.match(/(?:^|[;{\s])background(?:-color)?:\s*var\((--[a-z0-9-]+)\)/);
    const color = rule.match(/(?:^|[;{\s])color:\s*var\((--[a-z0-9-]+)\)/);
    if (background && color) assert.notEqual(background[1], color[1], `same token for both: ${rule.slice(0, 110)}`);
  }
});

test("every foreground/background pair the stylesheets actually declare is measured", async () => {
  // The palette audit tests 112 designed pairs. This tests the ones that exist:
  // any rule setting both a colour and a background from tokens gets measured
  // in both themes. It is the half a palette document cannot check, and it is
  // where a component override quietly reintroduces a failure.
  // Comments stripped first: this codebase explains its colour decisions by
  // quoting the declarations they replaced, so a raw scan happily "finds"
  // `background: var(--warning); color: var(--warning)` inside the paragraph
  // describing the bug where that was fixed.
  const strip = (styles) => styles.replace(/\/\*[\s\S]*?\*\//g, "");
  const sources = [
    ["workspace.css", strip(await read("../app/workspace.css"))],
    ["components.css", strip(await read("../app/components.css"))],
  ];
  const failures = [];
  const seen = new Set();
  for (const [file, styles] of sources) {
    for (const rule of styles.match(/[^{}]+\{[^}]*\}/g) ?? []) {
      const selector = rule.slice(0, rule.indexOf("{")).trim().replace(/\s+/g, " ");
      const background = rule.match(/(?:^|[;{\s])background(?:-color)?:\s*var\((--[a-z0-9-]+)\)/);
      const color = rule.match(/(?:^|[;{\s])color:\s*var\((--[a-z0-9-]+)\)/);
      if (!background || !color) continue;
      for (const [theme, tokens] of Object.entries(themes)) {
        if (!tokens.has(background[1]) || !tokens.has(color[1])) continue;   // a local variable, not a design token
        const key = `${theme}:${color[1]}:${background[1]}`;
        if (seen.has(key)) continue;
        seen.add(key);
        // A genuinely disabled control is held to the 3:1 product target, not
        // to 4.5:1 - WCAG exempts it, and dimming it further only makes the
        // disabled state harder to read without making it more obviously off.
        const gate = color[1] === "--text-disabled" ? 3 : 4.5;
        const measured = ratio(tokens, color[1], background[1]);
        if (measured < gate) failures.push(`${file} ${theme} ${selector} - ${color[1]} on ${background[1]} = ${round(measured)}:1 (gate ${gate})`);
      }
    }
  }
  assert.deepEqual(failures, [], `declared pairs below 4.5:1:\n${failures.join("\n")}`);
});

test("selection is its own surface, not the informational tint wearing its clothes", async () => {
  const styles = (await read("../app/workspace.css")) + (await read("../app/components.css"));
  // They looked alike and meant different things: one says "you picked this",
  // the other says "here is a fact".
  assert.match(styles, /tr\.selected \{ background: var\(--surface-selected\)/);
  assert.doesNotMatch(styles, /\.selected \{ background: var\(--accent-soft\)/);
  // And selection survives hover rather than being erased by it.
  assert.match(styles, /--surface-selected-hover/);
});

test("no operational surface carries a decorative gradient or a colour glow", async () => {
  const styles = await read("../app/workspace.css");
  const gradients = [...styles.matchAll(/^([^{\n]+)\{[^}]*(linear-gradient|radial-gradient)[^}]*\}/gm)].map((match) => match[1].trim());
  // The login splash is the one intentional exception: a brand panel on an
  // unauthenticated page, not a surface anyone reads data on. Skeletons sweep a
  // neutral highlight, which is a loading cue rather than decoration.
  const allowed = [".login-brand", ".loading-bar", ".loading-grid span"];
  const unexpected = gradients.filter((selector) => !allowed.some((entry) => selector.startsWith(entry)));
  assert.deepEqual(unexpected, [], `decorative gradient on an operational surface: ${unexpected.join(", ")}`);
  // Specifically: the full-page radial wash, and the blue-to-green blend on
  // Load more, which used two semantic hues as decoration.
  assert.doesNotMatch(styles, /\.app-shell \{\s*background:\s*\n?\s*radial-gradient/);
  assert.doesNotMatch(styles, /var\(--accent-soft\), var\(--success-soft\)/);
});
