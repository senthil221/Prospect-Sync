import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// FOUNDATION-02 from the UI redesign plan: contrast, focus, motion and the
// control-height exceptions. Each of these grew back once already, which is why
// they are asserted rather than merely fixed.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const declarations = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("/*") && !line.trimStart().startsWith("*"));

test("no control paints its text in its own background colour", async () => {
  const styles = (await read("../app/workspace.css")) + (await read("../app/components.css"));
  // CONTRAST-01 was `background: var(--warning); color: var(--warning)` on the
  // Boolean Apply button - one token for both, a 1:1 ratio, an invisible label.
  // The general form of that mistake is what this catches.
  const rules = styles.match(/\{[^}]*\}/g) ?? [];
  for (const rule of rules) {
    const background = rule.match(/(?:^|[;{\s])background(?:-color)?:\s*var\((--[a-z0-9-]+)\)/);
    const color = rule.match(/(?:^|[;{\s])color:\s*var\((--[a-z0-9-]+)\)/);
    if (background && color) {
      assert.notEqual(background[1], color[1],
        `a rule paints color and background with the same token (${background[1]}): ${rule.slice(0, 110)}`);
    }
  }
});

test("every search box shows focus, since its input suppresses its own ring", async () => {
  const workspace = await read("../app/workspace.css");
  const components = await read("../app/components.css");
  const styles = workspace + components;

  // These containers hold an input with `outline: 0`, so the container is the
  // only thing that can show focus. .workspace-search had no rule at all, so
  // tabbing into it showed nothing.
  for (const container of [".search", ".workspace-search", ".multi-value-control", ".token-input", ".filter-panel-search"]) {
    assert.ok(styles.includes(`${container}:focus-within`),
      `${container} suppresses its input's outline and must show focus itself`);
  }

  // And the global ring must still exist for everything else. It reads
  // --focus-color rather than --accent: the ring and the solid action fill are
  // separate roles now, because on a primary button they are the same value
  // and the ring is only visible thanks to the offset gap.
  const system = await read("../app/design-system.css");
  assert.match(system, /:focus-visible\s*\{\s*outline: 2px solid var\(--focus-color\)/);
});

test("controls use the two height tokens and nothing else", async () => {
  const system = await read("../app/design-system.css");
  assert.match(system, /--control-dense:\s*32px/);
  assert.match(system, /--control-standard:\s*40px/);

  // A raw pixel height on a control is the exception this replaced: the
  // stylesheet had grown 23 distinct heights between 20px and 48px, most of
  // them a pixel from a neighbour.
  //
  // Four things are deliberately not controls in this sense, and saying so here
  // is the point - an exemption nobody wrote down is how 23 heights happen.
  const exempt = [
    // The bordered box is the control; this is the text field inside it, which
    // sits on one line among the chips and must stay smaller than its parent.
    ".multi-value-control input", ".token-input input",
    // Icon above label, vertical: a different component, not a 32/40 control.
    ".sidebar nav button",
    // Visually hidden file input, sized to 1px on purpose.
    ".company-filter-import input",
  ];
  for (const path of ["../app/workspace.css", "../app/components.css"]) {
    const offenders = declarations(await read(path)).filter((line) => {
      const selector = line.slice(0, line.indexOf("{")).trim();
      if (!/\b(button|input|select)\b\s*(,|\{|$)/.test(selector + "{")) return false;   // the control is the subject
      if (exempt.some((entry) => selector.includes(entry))) return false;
      const height = line.match(/(min-)?height:\s*(\d+)px/);
      if (!height) return false;
      const width = line.match(/(min-)?width:\s*(\d+)px/);
      if (width && width[2] === height[2]) return false;                                 // a square icon or checkbox
      return Number(height[2]) >= 24;                                                    // below that it is an affordance, not a control
    });
    assert.deepEqual(offenders, [], `${path} has a control with a hardcoded height:\n${offenders.join("\n")}`);
  }

  // The base select carried min-height: 36px, which silently beat every
  // specific height because min-height wins when it is the larger of the two.
  // One line decided the height of every select in the product.
  const components = await read("../app/components.css");
  const selectRule = components.slice(components.indexOf("\nselect {"), components.indexOf("\nselect {") + 400);
  assert.match(selectRule, /min-height: var\(--control-dense\)/);
});

test("surface motion stays inside the 120-180ms band", async () => {
  const system = await read("../app/design-system.css");
  const durations = [...system.matchAll(/--duration-[a-z]+:\s*(\d+)ms/g)].map((match) => Number(match[1]));
  assert.ok(durations.length >= 3, "the motion scale should still be three durations");
  // Past 180ms a panel stops reading as a response to the click and starts
  // reading as a load. --duration-medium was 240ms.
  assert.ok(Math.max(...durations) <= 180, `a duration exceeds the 180ms ceiling: ${durations.join(", ")}ms`);

  // Reduced motion is still honoured globally rather than per component.
  assert.match(system, /@media \(prefers-reduced-motion: reduce\)/);
});

test("an action button is not shaped like a status chip", async () => {
  // The token contract: "6px fields, 10px controls/cards, 14px hero/dialog,
  // pill only for statuses/chips". Five action buttons wore --radius-full and
  // were sized by padding alone, so they sat at a different height AND a
  // different shape from every control beside them. .company-filter-import is
  // the one that showed it worst: a <label>, so the height pass - which matched
  // button/input/select/textarea - never saw it, and its flex parent stretched
  // it to full width as a lozenge.
  const styles = await read("../app/workspace.css");
  const controls = [".company-filter-import", ".company-filter-clear", ".company-bulk-clear", ".icp-toggle", ".bulk-domain-actions button"];
  for (const selector of controls) {
    const rule = styles.split("\n").find((line) => line.startsWith(`${selector} {`));
    assert.ok(rule, `${selector} should still exist`);
    assert.doesNotMatch(rule, /border-radius: var\(--radius-full\)/, `${selector} is a control, not a chip`);
    assert.match(rule, /min-height: var\(--control-(dense|standard)\)/, `${selector} must take a control height`);
    // Height without centring is what makes a control look wrong rather than
    // just tall: the label sits against the top edge.
    assert.match(rule, /align-items: center/, `${selector} must centre its label`);
  }
});
