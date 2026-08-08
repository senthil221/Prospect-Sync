import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("fails closed when the approved-user allowlist is missing", async () => {
  const [environment, auth, admin] = await Promise.all([
    readFile(new URL("../lib/supabase/env.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/auth.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/supabase/admin.ts", import.meta.url), "utf8"),
  ]);

  assert.match(environment, /configured\.length > 0 && configured\.includes/);
  assert.doesNotMatch(environment, /configured\.length === 0 \|\|/);
  assert.match(auth, /isAllowedEmail\(user\.email\)/);
  assert.match(admin, /SUPABASE_SERVICE_ROLE_KEY/);
});
