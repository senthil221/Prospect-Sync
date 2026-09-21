import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// Requested directly: reimporting a prospect who has been re-contacted should
// update Date Contacted to the new one automatically. Before this, the merge
// took whichever date was EARLIER (least()), so a reimport could never move
// the date forward - only the manual "Set Date Contacted" bulk action
// (set_client_date_contacted_v1, already unconditional) could.
test("a reimport overwrites Date Contacted when it carries one, and leaves it alone when it doesn't", async () => {
  const migration = await read("../supabase/migrations/20260921090000_a_reimport_updates_date_contacted_to_the_new_one.sql");

  // The accepted rule, exactly as asked: present -> overwrite regardless of
  // direction; absent -> keep whatever is already there. Not a "later wins"
  // comparison - that was offered and declined. (The old least() text still
  // appears in the file as the splice's own search target - that is what
  // v_anchor quotes to find and replace it, not a surviving behavior.)
  assert.match(migration, /date_added = coalesce\(excluded\.date_added, public\.client_prospects\.date_added\)/);
  assert.match(migration, /v_anchor constant text[\s\S]*?least\(public\.client_prospects\.date_added, excluded\.date_added\)/);

  // A SECURITY DEFINER function needs same-file revokes, same rule every other
  // migration here follows - checked by CI's migration guard too.
  assert.match(migration, /revoke execute on function public\.sync_client_prospects_from_lists\(\) from public, anon, authenticated;/);

  // The expression is proven directly against every combination the trigger's
  // ON CONFLICT can reach, not just left to "the function still compiles" -
  // a typo collapsing the two-way coalesce back toward a comparison would not
  // be a syntax error.
  assert.match(migration, /existing=% incoming=%: expected % but the new expression gives %/);
});
