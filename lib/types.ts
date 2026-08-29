import type { CompanyMergeMode } from "./company-merge-mode.ts";
export type Section = "overview" | "prospects" | "companies" | "clients" | "coverage" | "quality" | "imports";

export type ProspectFilterOperator = "contains" | "equals" | "not_contains" | "not_equals" | "empty" | "not_empty" | "boolean" | "number_ranges";
export type CompanyKeywordScope = "name" | "keywords" | "description";
export type ProspectFilter = { id: string; field: string; operator: ProspectFilterOperator; values: string[]; scopes?: CompanyKeywordScope[] };

export type ClientRecord = { id: string; name: string; list_count: number; prospect_count: number; cooldown_days?: number; icp_verified_count?: number; blocked_count?: number };
export type ListRecord = { id: string; name: string; data_source: string; source_file_name: string; uploaded_rows: number; unique_added: number; duplicates_linked: number; prospect_count: number; created_at: string; field_count: number; field_headers: string[] };
export type ProspectMembership = { listId: string; listName: string; clientId: string; clientName: string };
export type Prospect = Record<string, unknown> & { id: string; full_name: string; first_name?: string; last_name?: string; work_email: string; personal_email?: string; title: string; keywords?: string[]; company_name: string; company_domain: string; city?: string; state?: string; country?: string; location?: string; company_location?: string; company_city?: string; company_state?: string; company_country?: string; employee_count_min?: number; employee_count_max?: number; seniority?: string; department?: string; esp?: string; email_provider_type?: string; mx_records?: string[]; mx_status?: string; mx_checked_at?: string; client_count: number; list_count: number; list_names?: string[]; client_names?: string[]; list_memberships?: ProspectMembership[]; all_data: string | Record<string, string>; last_contacted_at?: string; next_eligible_at?: string; eligible?: boolean; client_date_contacted?: string | null; tags?: Array<{ id: string; name: string; color: string; clientId?: string | null }>; icp_verified_client_ids?: string[]; blocked_client_ids?: string[] };
export type Company = { id: string; name: string; domain: string; prospect_count: number; client_count: number; created_at: string; icp_validated?: boolean };
type ImportRecordBase = { id: string; file_name: string; data_source: string; processed_rows: number; status: string; created_at: string };
export type ProspectImportRecord = ImportRecordBase & { kind: "prospects"; client_name: string | null; list_name: string | null; unique_added: number; duplicates_linked: number };
export type CompanyImportRecord = ImportRecordBase & { kind: "companies"; added_count: number; updated_count: number; skipped_count: number };
export type ImportRecord = ProspectImportRecord | CompanyImportRecord;
export type DeleteKind = "import" | "list" | "client";
export type DeleteRequest = { kind: DeleteKind; id: string; name: string; context: string };
export type FileAudit = { headers: string[]; rows: number; populatedCells: number; invalidRows: number; sampled?: boolean };
export type InterruptedImport = { id: string; kind: "prospects" | "companies"; fileName: string; dataSource: string; status: string; committedRowOffset: number; totalRows: number; resumeFromRow: number; createdAt: string };
export type BackgroundImport = { id: string; fileName: string; status: string; committedRowOffset: number; totalRows: number | null; lastError: string; createdAt: string };
export type ImportResumeDetail = { id: string; kind: "prospects" | "companies"; listId: string | null; fileName: string; dataSource: string; status: string; ingestionMode?: string; committedRowOffset: number; totalRows: number | null; processedRows?: number; uniqueAdded?: number; duplicatesLinked?: number; processedBytes?: number; fileSizeBytes?: number | null; lastError?: string; headers: string[]; fieldMap: Record<string, string>; headerSignature: string; dateContacted?: string | null; mergeMode: CompanyMergeMode | null };
export type SavedView = { id: string; name: string; definition: { filters: ProspectFilter[]; columns: string[]; sort: string; direction: "asc" | "desc" } };
export type CoverageRow = { row: number; name: string; domain: string; status: "known" | "new"; matchedBy: string; matchedCompany: string; prospectCount: number; clientCount: number };
export type QualitySummary = { total: number; missingEmail: number; missingTitle: number; missingLinkedin: number; missingCompany: number; missingDomain: number; staleRecords: number; potentialDuplicateGroups: number };
export type BlocklistEntry = { id: string; kind: "domain" | "email"; value: string; reason: string; source: string; created_at: string };
export type EnrichmentPreview = { companies: number; fields: number; sample: Array<{ companyId: string; company: string; domain: string; fields: number }> };
export type PushResult = { added: number; alreadyPresent: number; blocked: number; queued: number };
export type IndexDrift = { prospects: number; indexed: number; missingFromIndex: number; staleInIndex: number; queued: number; queuedFailing: number; oldestQueuedAt: string | null };
export type DuplicateCandidate = { left: Prospect; right: Prospect; reason: string; confidence: number };

export const emptyStats = { prospects: 0, companies: 0, clients: 0, lists: 0, rowsImported: 0, duplicatesDetected: 0 };
