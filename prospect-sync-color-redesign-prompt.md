# Prospect Sync — All-Tab Color and Background Redesign Prompt

**Version 2 · revised 3 September 2026 · desktop-first, mobile last.**

Copy the implementation prompt below into the task that will make the UI changes. This version includes a calculated seed-palette audit, explicit allowed color pairs, combined-state rules, and a representative-screen visual trial. It defines the work needed to reach a 10/10 result; it does not claim that the application has already achieved one.

---

## Implementation prompt

Act as a senior product color designer, accessibility specialist, and frontend design-system engineer. Implement a complete, consistent color and background redesign of Prospect Sync across every existing workspace, nested tab, shared component, and interaction state.

Do not stop at a palette recommendation or change only the root background. Apply the system, verify its rendered usage, and report the evidence. Do not deploy or make production data mutations.

### 1. Outcome and scope

Create a calm, precise, premium-feeling interface for long sessions of scanning, filtering, importing, and reviewing large prospect datasets. Make content hierarchy and state recognition clearer without making the application visually louder.

Use one coherent direction: **Porcelain + Ink + Cobalt** in light mode and **Graphite + Cobalt** in dark mode.

Preserve the existing cobalt brand. Do not create a different brand palette for each tab. Green, amber, and red communicate states; they are not decorative page themes.

This is a color-system implementation, not a layout or business-logic rewrite. Preserve typography, spacing, navigation, data density, component geometry, query semantics, filtering, pagination, selection, imports, exports, membership, permissions, and API behavior. Minimal markup changes are allowed when necessary to add non-color state cues or correct theme application.

Keep mobile-specific refinement and validation last. Shared tokens must still work across viewport sizes; do not intentionally break existing small-screen layouts.

### 2. Inspect current code before changing it

Read AGENTS.md and any required local framework documentation. Record the current branch, commit, and working-tree status. Preserve other people's changes. The repository has progressed since the original audit: do not assume an old finding is still present.

Inspect the current versions of:

- `app/design-system.css`
- `app/workspace.css`
- `app/components.css`
- `app/globals.css`, `app/layout.tsx`, `app/DashboardApp.tsx`
- `app/components/ThemeToggle.tsx`
- every workspace and shared component containing color, inline styling, class-based status, SVG fill/stroke, or theme logic

Inventory literal colors, gradients, translucent backgrounds, opacity, colored shadows, legacy `--ph-*` aliases, and component overrides. Trace the cascade rather than appending a new blanket override stylesheet.

Inspect the existing `--on-accent` token and theme behavior. Preserve previous contrast fixes, including the Boolean Apply button, unless current measurement shows another issue.

Create a coverage ledger: workspace → nested tab → component → state → theme → screenshot/test evidence. Use it as the completion checklist. An unavailable screen is UNVERIFIED, not implicitly covered by a shared token change.

### 2A. Prove the visual direction on three screens before full rollout

Use Overview, People, and Import because they exercise overview hierarchy, dense data, and long forms. Render the current baseline and two constrained candidates with identical viewport, content, layout, typography, and interaction state:

- **A — Porcelain/Ink/Cobalt:** use the palette below. This is the default recommendation.
- **B — slightly warmer neutral surfaces:** change only the light canvas to `#F6F5F3` and nested field/header to `#FAFAF8`; retain A's text, cobalt, status, and dark-theme roles. This is a comparison candidate, not an asserted improvement. Recalculate every affected pair.

Inspect each at full size and as a reduced overview. Compare populated People rows, an expanded filter, selected and hovered rows, Import before validation and after an error, and Overview with a status message. Use current live read-only state where available; use labelled local fixtures for mutation/error states. Do not fabricate records or outcomes as live evidence.

Judge candidates against these questions, recording a concrete observation for each:

1. Is dense data easy to read without making helper text disappear?
2. Are primary action, selection, keyboard focus, and warning immediately distinguishable?
3. Are canvas, card, field, and floating surfaces clear without excessive outlines or shadows?
4. Does chromatic emphasis follow task importance rather than decoration?
5. Do the three screens feel like the same application?
6. Does dark mode preserve the same meaning and hierarchy?

Reject a candidate that fails any accessibility/state gate. Compare the remaining candidates visually; do not choose by a fabricated total score. Ask for a preference only if it materially changes the direction. Otherwise choose A when the evidence is tied, record why, and continue. Show the comparison in the handoff. Do not keep generating additional palettes without a specific unresolved problem.

### 3. Color theory and psychology: use evidence, not slogans

Apply these design principles:

1. **Lightness establishes hierarchy.** Differentiate the application canvas, task surfaces, nested controls, and overlays using controlled lightness steps.
2. **Chroma controls emphasis.** Keep large surfaces near-neutral; reserve stronger chroma for actions, selection, focus, and meaningful status.
3. **Hue carries consistent meaning.** The same hue/role mapping must mean the same thing in every workspace and theme.
4. **Judge colors in context.** Validate foreground/background combinations in the actual component, including surrounding colors, transparency, hover, selection, and overlays—not isolated swatches alone.
5. **Use OKLCH to construct or adjust tonal ramps.** Tune lightness and chroma deliberately instead of arbitrary HSL saturation shifts. Keep production colors within the chosen supported gamut and validate the final sRGB rendering for WCAG contrast. OKLCH lightness is not a substitute for a contrast calculation.
6. **Treat psychological associations as hypotheses.** Cobalt is chosen for existing brand continuity and a stable action convention, not because blue universally creates trust. Do not claim that a hue improves cognition, reduces fatigue, or changes behavior without relevant evidence.
7. **Do not impose a rigid 60/30/10 formula.** Most visible area should be neutral as a practical hierarchy choice, not a scientific percentage requirement.
8. **Prefer recognition over decoration.** Users should locate the selected row, primary action, warning, and failure immediately without scanning a rainbow of cards.

### 4. Starting palette: implement these semantic roles

Use the following sRGB values as the proposed baseline. Change a value only when rendered contrast, existing content, or visual evidence justifies it; document the adjustment. Reuse existing semantic tokens where their roles match. Add a token only for a genuinely distinct role.

| Semantic role / CSS token | Light | Dark |
|---|---|---|
| Canvas / `--canvas` | `#F5F6F8` | `#0F141C` |
| Main surface/sidebar/topbar / `--surface` | `#FFFFFF` | `#171E28` |
| Raised surface/menu/dialog / `--surface-raised` | `#FFFFFF` | `#202A36` |
| Nested field/header / `--surface-sunken` | `#F8FAFC` | `#121A24` |
| Neutral hover / `--surface-hover` | `#F1F4F8` | `#243041` |
| Neutral pressed / `--surface-active` | `#E6EBF2` | `#2C3B4F` |
| Selected / `--surface-selected` | `#EAF0FF` | `#22365B` |
| Selected + hover / `--surface-selected-hover` | `#E0E9FF` | `#2B416A` |
| Primary text / `--text-primary` | `#182230` | `#E9EEF5` |
| Secondary text / `--text-secondary` | `#475467` | `#B8C3D3` |
| Muted text/placeholder / `--text-tertiary` | `#5F6B7C` | `#93A1B5` |
| Disabled text / `--text-disabled` | `#748094` | `#8290A4` |
| Disabled background / `--surface-disabled` | `#E9EDF2` | `#273241` |
| Decorative divider / `--border-subtle` | `#E1E6EE` | `#2F3A49` |
| Essential control boundary / `--border-control` | `#6F7C90` | `#8292A8` |
| Solid action / `--accent` | `#2B59D9` | `#3B5FD6` |
| Solid action hover / `--accent-hover` | `#234BBC` | `#3354C2` |
| Solid action pressed / `--accent-pressed` | `#1D3F9E` | `#2C49A9` |
| Text/icon on solid action / `--on-accent` | `#FFFFFF` | `#FFFFFF` |
| Link/accent text / `--accent-text` | `#234BBC` | `#AEC5FF` |
| Focus indicator / `--focus-color` | `#2B59D9` | `#9EBAFF` |
| Overlay / `--overlay` | `rgba(15,20,28,0.40)` | `rgba(0,0,0,0.64)` |

If the repository already has an equivalent role under another name, reuse it and document the mapping instead of introducing a duplicate. Keep existing `--ph-*` aliases pointing to the appropriate semantic roles. `--accent-soft` must not serve simultaneously as every blue surface: distinguish selected rows from information badges.

State foreground/background pairs:

| State | Light foreground / background | Dark foreground / background |
|---|---|---|
| Success | `#087A55` / `#EAF8F0` | `#71D7B3` / `#132D25` |
| Warning | `#925F00` / `#FFF4D6` | `#F2C66D` / `#332A17` |
| Danger/error | `#B42318` / `#FFF0EE` | `#FFB4AB` / `#3A2022` |
| Information | `#1F4DB8` / `#EDF3FF` | `#ADC6FF` / `#202F50` |

Use the existing `--success`, `--warning`, `--danger`, and corresponding `*-soft` tokens for these badge/notice pairs; add `--info`/`--info-soft` only if equivalent roles do not exist. Essential status outlines may use the status foreground; subtle decorative outlines are separate.

For an existing solid final Delete/Cancel-import button, use explicit fill tokens in both themes: default `#B42318`, hover `#912018`, pressed `#7A1B14`, foreground `#FFFFFF`. Do not use the dark theme's pastel danger text as a solid fill. Do not add extra solid status buttons just to use a color.

Important token rules:

- Separate `--on-accent` from inverse text. White-on-accent must not become dark text merely because the theme changes.
- Separate accent fill, accent text, focus, and selection-background roles. One blue value cannot safely serve all four in both themes.
- Separate subtle decorative dividers from control boundaries needed to identify an input or state.
- **Pressed, selected, and selected-hover content uses primary/secondary text, never muted text.** Use role aliases such as `--text-on-selected` and `--text-on-pressed` where that prevents accidental inheritance.
- Disabled text is only for genuinely disabled controls, never ordinary metadata, placeholders, counts, or labels.
- Status text colors are not automatically suitable as solid button fills with white text. Define and measure explicit on-status/fill pairs wherever solid status buttons exist.
- Provide default, hover, pressed, focus, selected, selected-hover, disabled, loading, and error mappings. Define combined-state precedence; hover must not erase selection or an error indicator.

#### Allowed pairings and state precedence

| Component/state | Background | Foreground and distinguishing cue |
|---|---|---|
| Plain/hovered row | surface / surface-hover | Primary + muted metadata; hover never implies selection. |
| Pressed row/control | surface-active | Primary + secondary; never inherit muted metadata. |
| Selected row | surface-selected | Primary + secondary; checked box plus selected marker. |
| Selected + hover/press | surface-selected-hover | Primary + secondary; selection marker persists. |
| Primary button | accent / accent-hover / accent-pressed | on-accent in every state; no opacity reduction on active text. |
| Secondary/ghost button | surface / surface-hover / surface-active | Primary/secondary text; essential boundary uses border-control. |
| Field | surface-sunken | Primary text, tertiary placeholder; persistent visible label. |
| Invalid field | Keep neutral field background | Danger border + error icon/message; focus remains independently visible. |
| Status badge | Its own semantic soft background | Its matching semantic foreground; never inherit selected-row colors. |
| Disabled control | surface-disabled | text-disabled; preserve actual disabled semantics and show unmet requirements outside the control. |
| Focus-visible | Preserve underlying state | 2px opaque ring separated by a 2px gap matching the adjacent surface; use an outline/system colors in forced-colors mode. |
| Loading | Preserve control/page background | Readable text + progress cue; do not dim the whole container with opacity. |

Selection takes precedence over ordinary hover/press; focus is additive; errors keep their icon/message/border; disabled suppresses actionable hover. A selected row containing an error keeps its selected background and a self-contained error badge. Muted text is allowed only on canvas, main, raised, field, or neutral-hover surfaces; use secondary elsewhere unless separately measured. Mixed inline links need an underline or another non-color affordance, not just a different hue.

Do not apply border-control to every card/divider. It is for the graphical boundary needed to identify a control; decorative separation remains subtle. Measure a control boundary against both the field and adjacent parent surface. If a badge, tooltip, or menu uses a new pairing, add that exact pairing to the test ledger before considering it covered.

### 5. Background and surface architecture

Make these distinctions visible but restrained:

1. **Canvas:** consistent near-neutral background across all tabs.
2. **Task surface:** white/light-surface tables, cards, forms, and filter panels.
3. **Nested region:** subtle neutral fields, headers, code/data previews, and grouped controls.
4. **Floating surface:** menus, tooltips, drawers, and modals, separated by neutral shadow, border, or elevation—not a saturated tint.
5. **Semantic surface:** small, localized information/status areas.

Remove full-page radial glows, multicolor background gradients, decorative blue-to-green blends, and excessive blue shadows from operational screens. Do not tint all inputs, accordions, table headers, and cards pale blue. Blue must remain useful as a signal.

Use neutral shadows with modest opacity. Do not change hover geometry or animate entire backgrounds as part of this task.

In dark mode, floating surfaces become lighter than the canvas. Keep nested field styling explicit rather than mechanically inverting light-mode colors. Prefer opaque sticky headers on data screens so scrolling content does not change text contrast. If transparency remains, measure the worst-case composited background.

### 6. Apply the system to every workspace and nested tab

Inspect the actual UI and cover every existing tab; do not invent new pages or widgets.

**Overview**

- Neutral canvas, clean hero surface, neutral KPI cards.
- Cobalt belongs to the primary CTA, real links, and a restrained brand detail.
- Health is a compact labelled green status, not a green-tinted whole page.
- Reuse metrics use one purposeful accent, not a separate palette for each KPI.

**People database, Field coverage, Job titles, and client/list-scoped People**

- Neutral table body and header, neutral row hover, unmistakable blue selected state with checkbox/non-color cue.
- Dark readable data text. Color email/name text as a link only when actually interactive.
- White/neutral filter rail; neutral unselected controls; accent applied-filter chips and selected controls.
- Keep sorting, focus, hover, active filters, and selected rows visually distinguishable.
- Missing fields are neutral unless they represent an actionable quality warning.

**Companies and company details**

- Match the People workspace surface and interaction palette exactly.
- Covered/verified = labelled success; awaiting review = labelled warning when action is needed; no coverage = neutral, not automatically failure.
- Keep counts neutral or informational. Red belongs to destructive/error states.
- Remove decorative gradients from drawers and Load more controls.

**Clients & lists, client detail, uploaded lists, blocklists**

- Neutral cards/rows and stable accent navigation.
- Avatars may use a restrained deterministic identity palette, but colors must not imply client quality or status.
- Unassigned is neutral unless the product explicitly requires assignment.
- Blocked status uses a label and danger treatment; routine client/list information stays neutral.
- Match all nested tabs, pagination, menus, and confirmations to shared tokens.

**Coverage checker**

- Neutral initial/upload surfaces; cobalt for checking/progress and primary action.
- Known/covered may use labelled success; net-new is informational/neutral, not red.
- Results have clear semantic badges without coloring entire rows unnecessarily.

**Data quality**

- Healthy = green; action needed = amber; failed/destructive = red.
- Duplicate similarity/confidence is informational, not proof of safety; do not color a high confidence score green by default.
- Emphasize actual field differences and actionable issues, not every metric.
- Preserve readable status combinations in comparison cards and merge dialogs.

**Import CSV, People/Company modes, file/paste modes, mapping, progress, resume, results**

- Initial fields and requirements are neutral. Green is earned by validation/completion.
- Active step/progress = cobalt; waiting/not-started = neutral; interrupted = amber; failed = red; completed = green.
- Required fields do not make the whole untouched form red.
- Disabled CTA has explicit disabled tokens, not a random low-opacity blue.
- Review, partial success, skipped rows, and resume/cancel states remain distinct.

**Shared surfaces and other verified screens**

- Include navigation, theme control, tabs, buttons, inputs, checkboxes, switches, badges, chips, tooltips, menus, drawers, dialogs, skeletons, empty/error states, scrollbars, login, and error boundaries.
- Keep one selected-tab language: accent text plus underline/border or selected surface, not different treatment in every component.
- If charts exist, use labelled color-blind-considerate categorical sets or monotonic-lightness sequential scales. Do not add charts solely to showcase colors.

### 7. Accessibility and contrast gates

- Normal text, including placeholders and tooltip text: at least 4.5:1 against the actual background. Aim higher for dense primary data where practical.
- Qualifying large text: at least 3:1.
- Essential icons, control/state indicators, and boundaries needed to identify controls: at least 3:1 against adjacent colors. Decorative separators need not be artificially darkened.
- Show an opaque visible focus indicator; a faint translucent glow alone is insufficient. Use a contrasting offset/double ring where required.
- Pair color with text, icon, border, underline, checkbox, or shape for status and selection.
- Validate all prescribed state combinations in both themes. For genuinely inactive controls, use a product readability target of 3:1; this is not a WCAG requirement. Do not round a failing ratio up to a pass.
- Check forced-colors/high-contrast mode and grayscale. Color-vision-deficiency simulation is supplemental, not certification.
- Do not suppress user-selected theme or forced colors.

#### Seed-palette audit: 112 defined pair checks, zero failures

Calculated on 3 September 2026 using unrounded sRGB relative luminance and `(lighter + 0.05) / (darker + 0.05)`. This tests Candidate A's opaque values—not the CSS cascade, browser rendering, all conceivable pairings, or overall accessibility.

Per theme: primary/secondary/link text across eight neutral/selection backgrounds (24); muted text across its five permitted backgrounds (5); boundary/focus across eight backgrounds each (16); white text across three action and three danger fills (6); four status pairs (4); one disabled product-policy pair (1). Total: 56 per theme, 112 overall.

| Pair group | Light minimum | Dark minimum | Gate used |
|---|---:|---:|---:|
| Primary text | 13.179:1 | 8.715:1 | 4.5:1 |
| Secondary text | 6.321:1 | 5.701:1 | 4.5:1 |
| Link text | 6.159:1 | 5.917:1 | 4.5:1 |
| Muted text on permitted surfaces | 4.905:1 | 5.086:1 | 4.5:1 |
| Essential boundary | 3.480:1 | 3.206:1 | 3:1 |
| Focus against neutral/selection surface | 4.887:1 | 5.284:1 | 3:1 |
| White text on action/danger fills | 5.943:1 | 5.535:1 | 4.5:1 |
| Semantic badge text/background | 4.887:1 | 7.765:1 | 4.5:1 |
| Disabled control readability | 3.397:1 | 3.999:1 | 3:1 product target |

The previous light muted-on-pressed combination measured 4.153:1 and dark muted-on-pressed 4.338:1. These are prohibited pairings, not accepted exceptions.

Recompute actual pairs from final computed CSS, including inherited text, ancestor opacity, pseudo-elements, and composited backgrounds. Do not test only a copied palette object and call the application compliant. Include selected-hover, pressed, invalid+focus, disabled+selected where supported, and menus inside tinted containers. Focus on a solid button requires the separating gap; same-color ring/fill is not covered by the seed focus checks. If any actual combination fails, correct its role mapping rather than reducing the requirement, hiding the state, or rounding up.

### 8. Implementation and verification sequence

1. Record baseline commit, working-tree state, coverage ledger, and old-token → new-token mapping.
2. Capture current light/dark screens safely; do not trigger production mutations to manufacture states. Request authentication normally if needed, never bypass it. Clearly label local fixtures.
3. Implement the shared token/pair system in a local reversible patch and run Section 2A's Overview/People/Import comparison before full rollout.
4. Select the justified candidate, document the reason, and recompute affected pairs if it differs from A.
5. Remove conflicting component literals/gradients/opacity at their source. Avoid broad `!important` patches, unused theme variants, and needless dependencies.
6. Complete People and shared controls, then Companies and every remaining workspace/nested tab. Preserve existing non-color changes.
7. Add contrast regression tests that read the final tokens and state mappings; separately inspect computed browser styles to detect cascade/inheritance failures.
8. Run `npm run lint`, `npm run test:unit`, `npm run build`, and relevant existing/new UI tests after checking current scripts. Record commands and outcomes; do not claim tests passed if skipped.
9. Capture matched before/after screenshots at 1440×900, 1280×800, 1024×768, and 768×1024, plus 200% zoom, both themes, focus, overlay, and state combinations.
10. Apply the final mobile verification section only after desktop/tablet passes. Review the diff and report unavailable environments as UNVERIFIED.

Do not declare completion merely because token values changed or a screenshot looks attractive. Check all existing workspaces and component states.

### 9. Required handoff

Return:

1. Implemented palette and semantic token table, with any measured deviations from this proposal.
2. Concise rationale distinguishing design judgment from evidence-backed accessibility requirements.
3. Per-workspace completion checklist, including nested tabs and shared overlays.
4. Before/after screenshots in both themes for available states, with no unnecessary exposure of personal data.
5. Contrast matrix containing foreground, rendered background, ratio, state, theme, and pass/fail.
6. Changed files, tests run, remaining issues, and explicit UNVERIFIED gaps.

7. Three-screen candidate comparison with the chosen treatment and specific observations—not a self-awarded 10/10 score.

Completion gates:

- Every actual workspace/nested tab has an evidence-ledger entry in both themes.
- All allowed token pairs and actual rendered text/control-state checks pass; unsupported combinations are corrected, not omitted.
- Primary action, hover, pressed, selected, focus, disabled, warning, and error remain distinguishable with non-color cues.
- No unintended raw color, gradient, opacity, or shadow override bypasses the semantic system; intentional exceptions are documented.
- Existing non-color behavior and tests remain intact; no production data, auth, API, or deployment change occurred.
- Visual comparison and per-screen inspection are complete, or their gaps are explicitly reported without a completion claim.

Success means the application feels like one deliberate system: neutral backgrounds support the data, cobalt identifies interaction, semantic colors retain consistent meaning, and readable contrast survives every tab and state. Do not claim that any palette is scientifically “the best” or certify 10/10 without the verification evidence.

### 10. Mobile color verification — final phase

Keep this last; it is validation of the color work, not permission to redesign navigation/layout.

- Verify 390×844 and 360×800 in both themes after desktop/tablet checks pass.
- Check selected records, active filters/tabs, disabled import, validation, progress, sheets, menus, and dialogs with the software keyboard open where available.
- Ensure fixed/sticky/translucent surfaces do not expose an unexpected background behind text.
- Maintain visible focus, non-color selection/status cues, theme preference, and readable metadata at 200% zoom.
- Check forced-colors mode and grayscale; document unavailable device/simulation checks.
- Do not label mobile complete solely because it uses the same tokens as desktop.

---

## Evidence behind this prompt

- Minimum text contrast and measurement requirements: [W3C — Contrast Minimum](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).
- Essential control/state contrast: [W3C — Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html).
- Do not convey meaning through color alone: [W3C — Use of Color](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html).
- Perceptual color-space notation and behavior: [W3C — CSS Color 4](https://www.w3.org/TR/css-color-4/#ok-lab).
- Role-based color and light/dark surface layering: [IBM Carbon — Color Overview](https://carbondesignsystem.com/elements/color/overview/) and [Color Usage](https://carbondesignsystem.com/elements/color/usage/).
- Color preference can reflect learned associations; this does not establish universal hue-to-emotion effects for a CRM: [Palmer and Schloss — An Ecological Valence Theory of Human Color Preference](https://palmerlab.berkeley.edu/pdf/Palmer%26Schloss%282010%29.pdf).

The exact palette, tab mappings, emphasis rules, and workflow above are recommendations tailored to Prospect Sync, not requirements copied from these sources. The prospect-database engineering skill informed the protection of current filtering, selection, import, and membership workflows.
