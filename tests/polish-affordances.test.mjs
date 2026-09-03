import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// POLISH-01 and VIS-01: things that behaved like controls without being
// controls, and motion that outlasted the response it was describing.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("nothing inert pretends to be clickable", async () => {
  const styles = await read("../app/workspace.css");
  const overview = await read("../app/components/OverviewWorkspace.tsx");

  // VIS-01. The four KPI cards carried an arrow that faded in on hover, a
  // border that turned accent, and a two-pixel lift - three separate promises
  // that clicking would go somewhere. Nothing happened.
  assert.ok(!styles.includes(".metric-arrow"), "the arrow to nowhere is gone");
  assert.ok(!overview.includes("metric-arrow"));
  assert.ok(!styles.includes(".metric-card:hover"), "an inert card does not react to hover");

  // Every panel in the product lifted on hover, whether or not it did anything.
  assert.ok(!styles.includes(".panel:hover"), "a panel is a surface, not a button");

  // .client-card went with the client directory rewrite and left its styles
  // behind, still in the elevation and transition lists.
  assert.ok(!styles.includes(".client-card"));
});

test("a status nobody computes is not shown as a status", async () => {
  const overview = await read("../app/components/OverviewWorkspace.tsx");
  const styles = await read("../app/workspace.css");

  // "Database healthy · Live sync active" behind a green dot, and a "Healthy"
  // badge on the savings panel, were string literals. They would have said the
  // same thing during a total outage. The real health readout is computed in
  // the data quality centre, from actual index drift.
  assert.doesNotMatch(overview, /Database healthy|Live sync active/);
  assert.doesNotMatch(overview, /className="health-badge"/);
  assert.ok(!styles.includes(".hero-status"));
  assert.ok(!styles.includes(".health-badge"));

  // And the one that is real is still there.
  const quality = await read("../app/components/DataQualityPanel.tsx");
  assert.match(quality, /index-health-badge ok/);
  assert.match(quality, /indexHealthy \? " is up to date" : " needs attention"/);
});

test("no entrance outlasts the motion scale", async () => {
  const styles = (await read("../app/workspace.css")) + (await read("../app/components.css"));

  // The view transition was a 420ms rise staggered by up to 140ms, so the
  // fourth block of a screen settled well over half a second after the click
  // that asked for it - past the point where motion reads as a response and
  // into reading as a load. The design system's ceiling is 180ms.
  assert.ok(!styles.includes("animation-delay: .1s"), "the navigation stagger is gone");
  assert.ok(!styles.includes("ph-rise .42s"));

  // Every remaining duration is a token, except the looping indicators - a
  // shimmer or an indeterminate sweep is not an entrance and has no ceiling.
  const raw = [...styles.matchAll(/(?:animation|transition)[^;]*?([0-9.]+)s/g)]
    .filter((match) => !/shimmer|progress-pulse|ds-progress-sweep/.test(match[0]));
  assert.deepEqual(raw.map((match) => match[0]), [], "durations belong to the scale, not to the rule");
});

test("motion that does communicate is kept", async () => {
  const styles = await read("../app/workspace.css");
  // The primary button still presses: that motion describes something that
  // actually happened. Removing all of it is the opposite mistake.
  assert.match(styles, /\.primary:hover \{[^}]*transform: translateY\(-1px\)/);
  assert.match(styles, /\.primary:active[^{]*\{[^}]*transform: translateY\(1px\)/);
  // And reduced motion still switches the remaining transform off.
  assert.match(styles, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(styles, /\.primary:hover \{ transform: none; \}/);
});
