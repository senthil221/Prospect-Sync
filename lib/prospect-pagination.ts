import { createHash } from "node:crypto";

import { prospectCursorShapeSupported } from "./prospect-pagination-policy.ts";

export type ProspectCursor = {
  version: 1;
  queryHash: string;
  createdAt: string;
  id: string;
};

type CursorQueryIdentity = {
  search: string;
  filters: Array<{ field: string }>;
  sort: string;
  direction: string;
  clientId: string | null;
};

export function prospectCursorQueryHash(query: CursorQueryIdentity) {
  return createHash("sha256").update(JSON.stringify(query)).digest("base64url");
}

export function decodeProspectCursor(raw: string, expectedQueryHash: string): ProspectCursor | null {
  if (!raw || raw.length > 2048) return null;
  try {
    const value = JSON.parse(Buffer.from(raw, "base64url").toString("utf8")) as Partial<ProspectCursor>;
    if (value.version !== 1 || value.queryHash !== expectedQueryHash || typeof value.createdAt !== "string"
      || !Number.isFinite(Date.parse(value.createdAt)) || typeof value.id !== "string" || !value.id || value.id.length > 300) return null;
    return { version: 1, queryHash: value.queryHash, createdAt: value.createdAt, id: value.id };
  } catch { return null; }
}

export function encodeProspectCursor(row: unknown, queryHash: string) {
  if (!row || typeof row !== "object") return null;
  const createdAt = "created_at" in row ? String(row.created_at ?? "") : "";
  const id = "id" in row ? String(row.id ?? "") : "";
  if (!Number.isFinite(Date.parse(createdAt)) || !id) return null;
  return Buffer.from(JSON.stringify({ version: 1, queryHash, createdAt, id } satisfies ProspectCursor), "utf8").toString("base64url");
}

export function isProspectCursorEligible(input: {
  featureEnabled: boolean;
  requested: boolean;
  page: number;
  rawCursor: string;
  sort: string;
  direction: string;
  companyScoped: boolean;
  filters: Array<{ field: string }>;
}) {
  return input.featureEnabled && input.requested
    && prospectCursorShapeSupported(input)
    && (input.page === 1 ? !input.rawCursor : Boolean(input.rawCursor));
}
