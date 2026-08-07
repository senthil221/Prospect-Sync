import { ensureDatabase, getD1 } from "../../../../db/runtime";
import { mapProspect, mergeRaw, normalizeText } from "../../../../db/normalize";

type ExistingProspect = Record<string, string | null> & { id: string; all_data: string | null };

export async function POST(request: Request) {
  await ensureDatabase();
  const { importId, listId, headers, rows } = await request.json() as {
    importId?: string; listId?: string; headers?: string[]; rows?: string[][];
  };
  if (!importId || !listId || !headers?.length || !rows?.length) {
    return Response.json({ error: "Invalid import chunk." }, { status: 400 });
  }
  const db = getD1();
  let uniqueAdded = 0;
  let duplicatesLinked = 0;
  let skipped = 0;

  for (const values of rows) {
    const prospect = mapProspect(headers, values);
    if (!prospect.identifiers.length) { skipped += 1; continue; }
    let existing: ExistingProspect | null = null;
    for (const identifier of prospect.identifiers) {
      existing = await db.prepare(`SELECT p.* FROM prospect_identifiers pi JOIN prospects p ON p.id = pi.prospect_id
        WHERE pi.type = ? AND pi.value = ? LIMIT 1`).bind(identifier.type, identifier.value).first<ExistingProspect>();
      if (existing) break;
    }

    const companyKey = prospect.companyDomain
      ? `domain:${prospect.companyDomain}`
      : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
    const prospectId = existing?.id ?? crypto.randomUUID();
    const merged = mergeRaw(existing?.all_data ?? null, prospect.raw);
    const statements: D1PreparedStatement[] = [];

    if (companyKey) {
      statements.push(db.prepare(`INSERT INTO companies (id, name, normalized_name, domain, normalized_domain, all_data)
        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
        name = CASE WHEN companies.name = '' THEN excluded.name ELSE companies.name END,
        domain = CASE WHEN companies.domain = '' THEN excluded.domain ELSE companies.domain END,
        all_data = CASE WHEN companies.all_data = '{}' THEN excluded.all_data ELSE companies.all_data END,
        updated_at = CURRENT_TIMESTAMP`).bind(companyKey, prospect.companyName, normalizeText(prospect.companyName), prospect.companyDomain, prospect.companyDomain, JSON.stringify(prospect.raw)));
    }

    if (!existing) {
      statements.push(db.prepare(`INSERT INTO prospects (id, first_name, last_name, full_name, work_email, personal_email,
        mobile_number, linkedin_url, title, seniority, department, city, state, country, company_id, all_data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).bind(
        prospectId, prospect.firstName, prospect.lastName, prospect.fullName, prospect.workEmail, prospect.personalEmail,
        prospect.mobileNumber, prospect.linkedinUrl, prospect.title, prospect.seniority, prospect.department,
        prospect.city, prospect.state, prospect.country, companyKey || null, JSON.stringify(prospect.raw)));
      uniqueAdded += 1;
    } else {
      statements.push(db.prepare(`UPDATE prospects SET
        first_name = CASE WHEN first_name = '' THEN ? ELSE first_name END,
        last_name = CASE WHEN last_name = '' THEN ? ELSE last_name END,
        full_name = CASE WHEN full_name = '' THEN ? ELSE full_name END,
        work_email = CASE WHEN work_email = '' THEN ? ELSE work_email END,
        personal_email = CASE WHEN personal_email = '' THEN ? ELSE personal_email END,
        mobile_number = CASE WHEN mobile_number = '' THEN ? ELSE mobile_number END,
        linkedin_url = CASE WHEN linkedin_url = '' THEN ? ELSE linkedin_url END,
        title = CASE WHEN title = '' THEN ? ELSE title END,
        seniority = CASE WHEN seniority = '' THEN ? ELSE seniority END,
        department = CASE WHEN department = '' THEN ? ELSE department END,
        city = CASE WHEN city = '' THEN ? ELSE city END,
        state = CASE WHEN state = '' THEN ? ELSE state END,
        country = CASE WHEN country = '' THEN ? ELSE country END,
        company_id = COALESCE(company_id, ?), all_data = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?`).bind(
        prospect.firstName, prospect.lastName, prospect.fullName, prospect.workEmail, prospect.personalEmail,
        prospect.mobileNumber, prospect.linkedinUrl, prospect.title, prospect.seniority, prospect.department,
        prospect.city, prospect.state, prospect.country, companyKey || null, JSON.stringify(merged), prospectId));
      duplicatesLinked += 1;
    }

    for (const identifier of prospect.identifiers) {
      statements.push(db.prepare("INSERT OR IGNORE INTO prospect_identifiers (type, value, prospect_id) VALUES (?, ?, ?)").bind(identifier.type, identifier.value, prospectId));
    }
    statements.push(db.prepare(`INSERT INTO list_memberships (list_id, prospect_id, import_id, raw_data)
      VALUES (?, ?, ?, ?) ON CONFLICT(list_id, prospect_id) DO UPDATE SET raw_data = excluded.raw_data, import_id = excluded.import_id`).bind(listId, prospectId, importId, JSON.stringify(prospect.raw)));
    await db.batch(statements);
  }

  await db.prepare(`UPDATE imports SET processed_rows = processed_rows + ?, unique_added = unique_added + ?,
    duplicates_linked = duplicates_linked + ? WHERE id = ?`).bind(rows.length, uniqueAdded, duplicatesLinked, importId).run();
  return Response.json({ processed: rows.length, uniqueAdded, duplicatesLinked, skipped });
}
