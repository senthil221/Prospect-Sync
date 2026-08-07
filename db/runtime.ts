import { env } from "cloudflare:workers";

export function getD1(): D1Database {
  if (!env.DB) throw new Error("Database binding is unavailable.");
  return env.DB;
}

const statements = [
  `CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)`,
  `CREATE TABLE IF NOT EXISTS lists (id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES clients(id), name TEXT NOT NULL, source_file_name TEXT NOT NULL DEFAULT '', uploaded_rows INTEGER NOT NULL DEFAULT 0, unique_added INTEGER NOT NULL DEFAULT 0, duplicates_linked INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)`,
  `CREATE TABLE IF NOT EXISTS companies (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', normalized_name TEXT NOT NULL DEFAULT '', domain TEXT NOT NULL DEFAULT '', normalized_domain TEXT NOT NULL DEFAULT '', all_data TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)`,
  `CREATE TABLE IF NOT EXISTS prospects (id TEXT PRIMARY KEY, first_name TEXT NOT NULL DEFAULT '', last_name TEXT NOT NULL DEFAULT '', full_name TEXT NOT NULL DEFAULT '', work_email TEXT NOT NULL DEFAULT '', personal_email TEXT NOT NULL DEFAULT '', mobile_number TEXT NOT NULL DEFAULT '', linkedin_url TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', seniority TEXT NOT NULL DEFAULT '', department TEXT NOT NULL DEFAULT '', city TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT '', country TEXT NOT NULL DEFAULT '', company_id TEXT REFERENCES companies(id), all_data TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)`,
  `CREATE TABLE IF NOT EXISTS prospect_identifiers (type TEXT NOT NULL, value TEXT NOT NULL, prospect_id TEXT NOT NULL REFERENCES prospects(id), created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(type, value))`,
  `CREATE TABLE IF NOT EXISTS imports (id TEXT PRIMARY KEY, client_id TEXT NOT NULL REFERENCES clients(id), list_id TEXT NOT NULL REFERENCES lists(id), file_name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'processing', total_rows INTEGER NOT NULL DEFAULT 0, processed_rows INTEGER NOT NULL DEFAULT 0, unique_added INTEGER NOT NULL DEFAULT 0, duplicates_linked INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, completed_at TEXT)`,
  `CREATE TABLE IF NOT EXISTS list_memberships (list_id TEXT NOT NULL REFERENCES lists(id), prospect_id TEXT NOT NULL REFERENCES prospects(id), import_id TEXT NOT NULL REFERENCES imports(id), raw_data TEXT NOT NULL DEFAULT '{}', imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(list_id, prospect_id))`,
  `CREATE INDEX IF NOT EXISTS idx_lists_client_id ON lists(client_id)`,
  `CREATE INDEX IF NOT EXISTS idx_companies_normalized_domain ON companies(normalized_domain)`,
  `CREATE INDEX IF NOT EXISTS idx_companies_normalized_name ON companies(normalized_name)`,
  `CREATE INDEX IF NOT EXISTS idx_prospects_company_id ON prospects(company_id)`,
  `CREATE INDEX IF NOT EXISTS idx_prospects_full_name ON prospects(full_name)`,
  `CREATE INDEX IF NOT EXISTS idx_identifiers_prospect_id ON prospect_identifiers(prospect_id)`,
  `CREATE INDEX IF NOT EXISTS idx_memberships_prospect_id ON list_memberships(prospect_id)`,
  `CREATE INDEX IF NOT EXISTS idx_imports_created_at ON imports(created_at)`,
];

let initialized = false;

export async function ensureDatabase() {
  if (initialized) return;
  const db = getD1();
  await db.batch(statements.map((statement) => db.prepare(statement)));
  initialized = true;
}
