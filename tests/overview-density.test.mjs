import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { formatShare } from "../lib/quality-issues.ts";

// The Overview read as sparse, and both causes were decisions rather than CSS:
// it fetched less than it had room for, and it led with its worst number.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("the recent-imports column is filled from the data, not padded with space", async () => {
  const route = await read("../app/api/dashboard/route.ts");
  // Six rows in a column tall enough for eleven. Both kinds are over-fetched so
  // the merge has enough of each to sort from before it is cut.
  assert.equal(route.match(/\.limit\(12\)/g)?.length, 2, "both import kinds must over-fetch");
  assert.match(route, /\.slice\(0, 12\)/);
  assert.doesNotMatch(route, /\.limit\(6\)/);
});

test("the reuse panel leads with the achievement, not the ratio", async () => {
  const overview = await read("../app/components/OverviewWorkspace.tsx");
  // 5,384 records nobody had to buy again is the fact. The same fact as a
  // share of every row ever imported is 0.74%, and putting THAT in accent blue
  // at 26px made the panel advertise its worst number.
  assert.match(overview, /className="coverage-spotlight"><strong><CountUp value=\{stats\.duplicatesDetected\}\/><\/strong>/);
  assert.doesNotMatch(overview, /\{reuseRate\}%/);
  // The share survives as a supporting row, through the formatter that refuses
  // to round a sub-1% value up to a number that looks deliberate.
  assert.match(overview, /const reuseShare = formatShare\(stats\.duplicatesDetected, stats\.rowsImported\)/);
  assert.match(overview, /<span>Matched on import<\/span><strong>\{reuseShare\}<\/strong>/);
  assert.equal(formatShare(5384, 724991), "<1%");
  assert.notEqual(formatShare(5384, 724991), "1%");

  // The bar and its caption describe the same number. The bar used to plot
  // reuse while the caption explained something else.
  // The bar's width is a custom property now, so it can be animated from zero
  // on the way in without the keyframe having to know the value. Same number.
  assert.match(overview, /coverage-track"><i style=\{\{ "--fill": `\$\{Math\.min\(100, uniqueRate\)\}%` \} as CSSProperties\}/);
  assert.match(overview, /\{uniqueRate\}% of every row you have ever imported/);
});

test("a metric tile is sized by its content", async () => {
  const styles = await read("../app/workspace.css");
  // 116px of card to hold one number, on a page whose complaint was that it
  // felt sparse - the padding was doing work the content should.
  assert.match(styles, /\.metric-card \{ position: relative; min-height: 96px/);
  assert.doesNotMatch(styles, /\.metric-card \{ position: relative; min-height: 116px/);
});
