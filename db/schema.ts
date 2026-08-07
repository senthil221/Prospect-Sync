import { sql } from "drizzle-orm";
import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

export const clients = sqliteTable("clients", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  normalizedName: text("normalized_name").notNull(),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [uniqueIndex("idx_clients_normalized_name").on(table.normalizedName)]);

export const lists = sqliteTable("lists", {
  id: text("id").primaryKey(),
  clientId: text("client_id").notNull().references(() => clients.id),
  name: text("name").notNull(),
  sourceFileName: text("source_file_name").notNull().default(""),
  uploadedRows: integer("uploaded_rows").notNull().default(0),
  uniqueAdded: integer("unique_added").notNull().default(0),
  duplicatesLinked: integer("duplicates_linked").notNull().default(0),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [index("idx_lists_client_id").on(table.clientId)]);

export const companies = sqliteTable("companies", {
  id: text("id").primaryKey(),
  name: text("name").notNull().default(""),
  normalizedName: text("normalized_name").notNull().default(""),
  domain: text("domain").notNull().default(""),
  normalizedDomain: text("normalized_domain").notNull().default(""),
  allData: text("all_data", { mode: "json" }).$type<Record<string, string>>().notNull().default({}),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
  updatedAt: text("updated_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [
  index("idx_companies_normalized_name").on(table.normalizedName),
  index("idx_companies_normalized_domain").on(table.normalizedDomain),
]);

export const prospects = sqliteTable("prospects", {
  id: text("id").primaryKey(),
  firstName: text("first_name").notNull().default(""),
  lastName: text("last_name").notNull().default(""),
  fullName: text("full_name").notNull().default(""),
  workEmail: text("work_email").notNull().default(""),
  personalEmail: text("personal_email").notNull().default(""),
  mobileNumber: text("mobile_number").notNull().default(""),
  linkedinUrl: text("linkedin_url").notNull().default(""),
  title: text("title").notNull().default(""),
  seniority: text("seniority").notNull().default(""),
  department: text("department").notNull().default(""),
  city: text("city").notNull().default(""),
  state: text("state").notNull().default(""),
  country: text("country").notNull().default(""),
  companyId: text("company_id").references(() => companies.id),
  allData: text("all_data", { mode: "json" }).$type<Record<string, string>>().notNull().default({}),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
  updatedAt: text("updated_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [
  index("idx_prospects_company_id").on(table.companyId),
  index("idx_prospects_full_name").on(table.fullName),
]);

export const prospectIdentifiers = sqliteTable("prospect_identifiers", {
  type: text("type").notNull(),
  value: text("value").notNull(),
  prospectId: text("prospect_id").notNull().references(() => prospects.id),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [
  primaryKey({ columns: [table.type, table.value] }),
  index("idx_prospect_identifiers_prospect_id").on(table.prospectId),
]);

export const imports = sqliteTable("imports", {
  id: text("id").primaryKey(),
  clientId: text("client_id").notNull().references(() => clients.id),
  listId: text("list_id").notNull().references(() => lists.id),
  fileName: text("file_name").notNull(),
  status: text("status").notNull().default("processing"),
  totalRows: integer("total_rows").notNull().default(0),
  processedRows: integer("processed_rows").notNull().default(0),
  uniqueAdded: integer("unique_added").notNull().default(0),
  duplicatesLinked: integer("duplicates_linked").notNull().default(0),
  createdAt: text("created_at").notNull().default(sql`CURRENT_TIMESTAMP`),
  completedAt: text("completed_at"),
}, (table) => [index("idx_imports_created_at").on(table.createdAt)]);

export const listMemberships = sqliteTable("list_memberships", {
  listId: text("list_id").notNull().references(() => lists.id),
  prospectId: text("prospect_id").notNull().references(() => prospects.id),
  importId: text("import_id").notNull().references(() => imports.id),
  rawData: text("raw_data", { mode: "json" }).$type<Record<string, string>>().notNull().default({}),
  importedAt: text("imported_at").notNull().default(sql`CURRENT_TIMESTAMP`),
}, (table) => [
  primaryKey({ columns: [table.listId, table.prospectId] }),
  index("idx_list_memberships_prospect_id").on(table.prospectId),
]);
