import { resolveMx } from "node:dns/promises";
import {
  classifyMxRecords as classify,
  lookupEmailProvider as lookup,
  parseDnsOverHttpsMx as parseDoh,
} from "../worker/email-provider-core.mjs";

// The classification itself lives in worker/email-provider-core.mjs, shared
// with the ICP worker's continuous MX scan and the ESP filter picker.

export type EmailProviderCategory = "SEG" | "Mailbox provider" | "Email relay" | "Unknown";
export type MxLookupStatus = "resolved" | "no_mx" | "lookup_failed";

export type EmailProviderResult = {
  esp: string;
  category: EmailProviderCategory;
  mxRecords: string[];
  status: MxLookupStatus;
};

export function parseDnsOverHttpsMx(payload: unknown): Array<{ priority: number; exchange: string }> {
  return parseDoh(payload);
}

export function classifyMxRecords(records: Array<string | { exchange: string; priority?: number }>): EmailProviderResult {
  return classify(records) as EmailProviderResult;
}

export async function lookupEmailProvider(domain: string): Promise<EmailProviderResult> {
  return await lookup(domain, { resolveMx }) as EmailProviderResult;
}
