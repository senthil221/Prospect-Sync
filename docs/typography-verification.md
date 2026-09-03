# Prospect Sync typography verification

Date: 3 September 2026. Scope: UI implementation prepared for the production release workflow on `main`.

## Decisions

- Keep locally hosted Inter Variable, including italic. No new font download or dependency.
- Keep optical sizing. Use open 4/6/9 and distinct I/l variants; restore the default double-storey a.
- Use relative text sizes: 14px working text, 13px supporting text, 12px captions at the normal 16px browser root. The root itself is not reduced to 14px.
- Default table text is 14px; the existing compact preference opts into 13px and 36px rows. Body text remains proportional. Numeric columns and metrics use tabular digits; numeric headers and cells align right together.
- Use 500 for normal control/identity emphasis and 600 for page headings. Keep fuller spacing and sentence-case table headers.
- Keep full names and emails in hover titles when their visible cells truncate. Existing row buttons and detail-opening behavior remain intact.
- Let filter labels wrap, metric grids reflow and mode/step controls grow with enlarged text. Do not shrink information to fit a fixed box.
- The separate `app/typography.css` layer loads last, avoiding interference with the concurrent color-token work. No query, API, import, membership or authentication behavior changed.

## Verification

- Production build, including TypeScript: passed.
- Full lint: passed with one fixture-only Next `<head>` warning; the standalone fixture now has a documented local exemption. Lint of all affected files subsequently passed without warnings.
- Six new typography tests: passed. They check the scale, font configuration, density opt-in, numeric roles, reflow safeguards and server-rendered real table rows.
- Typography, existing UI-v2 and row/dialog regression subset: 12/12 passed.
- Latest full unit suite: 321/321 passed, including the measured light/dark color-contrast matrix and the semantic `--focus-color` assertion.
- Final diff whitespace check: passed.

Browser checks used a loopback-only static fixture with synthetic records and the real `ProspectTableRow`, `CompanyTableRow`, `Tabs` and `ImportStepper` components. Styles were the production CSS chunks, in the exact order recorded by Next's build manifest. This is not an authenticated, hydrated application session.

| Check | Observed result |
| --- | --- |
| 1440 × 900, light, normal text | Inter loaded; table text and filter headings 14px; no vertically clipped sample controls |
| 1280px, normal text | Production cascade and heading/control weights verified |
| 1024 × 900, dark, compact | Table text and row identities 13px; rows 36px; no clipped sample controls |
| 1024 × 900, dark, compact, 125% text | Table text 16.25px; filter headings 17.5px; metric cards reflowed without overflow |
| 1280 × 900, 200% text | Body/table text 28px; mode buttons and import steps grew; no clipped sample controls; sidebar scrolls |

The initial visual checks caught and corrected the old small filter-heading rule, fixed-height mode controls, import-step number clipping and overly narrow metric cards. Text enlargement was tested by changing the fixture's root font percentage, not by claiming a browser page-zoom test.

## Repeat the local fixture check

```sh
npm run build
node --experimental-strip-types --test tests/typography.test.mjs
node --import ./tests/helpers/tsx-loader.mjs scripts/typography-preview.mjs
```

Open `http://127.0.0.1:3217/`. Query parameters support `theme=dark`, `density=compact` and `scale=125` or `scale=200`. The fixture is not shipped as an app route and does not connect to customer data. Rebuild and restart the fixture server after CSS changes.

After release, check the authenticated workspaces with real data, font fallback for any required non-Latin scripts, actual browser zoom and keyboard workflows. No authenticated all-tabs interaction verification is claimed here.

## Mobile (last)

At 390 × 844, text remained 14px in the horizontally scrolling table and 16px in form inputs. After the metric-grid correction, the page measured 380px wide inside the 390px viewport (the remainder was the scrollbar), with no unintended page overflow or clipped sample controls. Cards stack to preserve full counts. This was a Chromium viewport check, not an iOS/Safari device test or a full mobile redesign.
