<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# Codex workflow

Classify every product change before editing:

- **TRIVIAL:** The root `gpt-5.6-sol` Medium agent implements directly. Never invoke Astra.
- **NORMAL:** Invoke `planner_normal`, wait for its concise plan, then the root Sol Medium agent implements and validates it.
- **HIGH:** Invoke `planner_high`, wait for its concise plan, then invoke `implementer_high` to implement and validate it.

HIGH means work materially involving Supabase migrations or schema, RLS, authentication or authorization, security, destructive data operations, concurrency, major architecture changes, or several tightly coupled systems.

Run agents sequentially. Astra plans only and inspects only relevant code. Sol owns all edits, debugging, tests, builds, and routine corrections. Return to the matching Astra planner only when Sol finds the architecture fundamentally wrong.

For this live Supabase app: never expose service-role credentials, disable RLS to bypass access problems, or reset/destroy production data. Use migrations for persistent schema changes and prefer small, backward-compatible changes.

Use only checks relevant to the change: `npm run lint`, `npm run test:unit`, `npm run build`, and `npm run test:e2e`. `npm test` runs the build and unit tests. There is no standalone typecheck script.
