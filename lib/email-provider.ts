import { resolveMx } from "node:dns/promises";

export type EmailProviderCategory = "SEG" | "Mailbox provider" | "Email relay" | "Unknown";
export type MxLookupStatus = "resolved" | "no_mx" | "lookup_failed";

export type EmailProviderResult = {
  esp: string;
  category: EmailProviderCategory;
  mxRecords: string[];
  status: MxLookupStatus;
};

type ProviderSignature = {
  name: string;
  category: Exclude<EmailProviderCategory, "Unknown">;
  matches: (host: string) => boolean;
};

const suffix = (...values: string[]) => (host: string) => values.some((value) => host === value || host.endsWith(`.${value}`));
const includes = (...values: string[]) => (host: string) => values.some((value) => host.includes(value));

// SEG signatures intentionally come first. A protected domain may publish its
// downstream mailbox provider as a lower-priority fallback MX record.
const providerSignatures: ProviderSignature[] = [
  { name: "Mimecast", category: "SEG", matches: suffix("mimecast.com") },
  { name: "Proofpoint", category: "SEG", matches: suffix("pphosted.com", "ppe-hosted.com", "ppops.net") },
  { name: "Barracuda", category: "SEG", matches: suffix("ess.barracudanetworks.com") },
  { name: "Cisco Secure Email", category: "SEG", matches: suffix("iphmx.com") },
  { name: "Sophos Email", category: "SEG", matches: (host) => suffix("sophos.com")(host) && includes("hydra", ".ctr.")(host) },
  { name: "Trend Micro Email Security", category: "SEG", matches: includes(".tmes", ".tmems-") },
  { name: "Hornetsecurity", category: "SEG", matches: suffix("hornetsecurity.com", "cloud-security.net") },
  { name: "Forcepoint Email Security", category: "SEG", matches: suffix("mailcontrol.com") },
  { name: "SpamTitan", category: "SEG", matches: suffix("spamtitan.com") },
  { name: "Cloudflare Area 1", category: "SEG", matches: suffix("area1protect.com") },

  { name: "Google Workspace", category: "Mailbox provider", matches: (host) => host === "smtp.google.com" || host === "aspmx.l.google.com" || host.endsWith(".aspmx.l.google.com") || host.endsWith(".googlemail.com") },
  { name: "Microsoft 365", category: "Mailbox provider", matches: suffix("mail.protection.outlook.com", "mx.microsoft") },
  { name: "Zoho Mail", category: "Mailbox provider", matches: suffix("zoho.com", "zoho.eu", "zoho.in", "zohomail.com") },
  { name: "Fastmail", category: "Mailbox provider", matches: suffix("messagingengine.com") },
  { name: "Proton Mail", category: "Mailbox provider", matches: suffix("protonmail.ch") },
  { name: "Apple iCloud Mail", category: "Mailbox provider", matches: suffix("mail.icloud.com") },
  { name: "Amazon WorkMail", category: "Mailbox provider", matches: suffix("awsapps.com") },
  { name: "Titan Mail", category: "Mailbox provider", matches: suffix("titan.email") },
  { name: "GoDaddy Email", category: "Mailbox provider", matches: suffix("secureserver.net") },
  { name: "Namecheap Private Email", category: "Mailbox provider", matches: suffix("privateemail.com") },
  { name: "Rackspace Email", category: "Mailbox provider", matches: suffix("emailsrvr.com") },
  { name: "Yahoo Mail", category: "Mailbox provider", matches: suffix("yahoodns.net") },
  { name: "Yandex Mail", category: "Mailbox provider", matches: suffix("yandex.net") },

  { name: "Cloudflare Email Routing", category: "Email relay", matches: suffix("mx.cloudflare.net") },
  { name: "Amazon SES", category: "Email relay", matches: (host) => host.startsWith("inbound-smtp.") && suffix("amazonaws.com")(host) },
  { name: "Mailgun", category: "Email relay", matches: suffix("mailgun.org") },
];

function normalizeMxHost(value: string) {
  return value.trim().toLowerCase().replace(/\.$/, "");
}

export function parseDnsOverHttpsMx(payload: unknown) {
  if (!payload || typeof payload !== "object") throw new Error("Invalid DNS-over-HTTPS response.");
  const response = payload as { Status?: unknown; Answer?: unknown };
  const status = Number(response.Status);
  if (status === 3) return [];
  if (status !== 0) throw new Error(`DNS-over-HTTPS lookup failed with status ${status}.`);
  if (!Array.isArray(response.Answer)) return [];
  return response.Answer.flatMap((answer) => {
    if (!answer || typeof answer !== "object") return [];
    const record = answer as { type?: unknown; data?: unknown };
    if (Number(record.type) !== 15 || typeof record.data !== "string") return [];
    const match = record.data.trim().match(/^(\d+)\s+(.+)$/);
    return match ? [{ priority: Number(match[1]), exchange: normalizeMxHost(match[2]) }] : [];
  }).sort((left, right) => left.priority - right.priority);
}

async function resolveMxOverHttps(domain: string) {
  const endpoint = new URL("https://cloudflare-dns.com/dns-query");
  endpoint.searchParams.set("name", domain);
  endpoint.searchParams.set("type", "MX");
  const response = await fetch(endpoint, {
    headers: { accept: "application/dns-json" },
    signal: AbortSignal.timeout(8_000),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`DNS-over-HTTPS request failed with HTTP ${response.status}.`);
  return parseDnsOverHttpsMx(await response.json());
}

export function classifyMxRecords(records: Array<string | { exchange: string; priority?: number }>): EmailProviderResult {
  const mxRecords = [...new Set(records.map((record) => normalizeMxHost(typeof record === "string" ? record : record.exchange)).filter(Boolean))];
  if (!mxRecords.length) return { esp: "No MX record", category: "Unknown", mxRecords, status: "no_mx" };

  for (const signature of providerSignatures) {
    if (mxRecords.some(signature.matches)) {
      return { esp: signature.name, category: signature.category, mxRecords, status: "resolved" };
    }
  }

  return { esp: "Custom / unknown", category: "Unknown", mxRecords, status: "resolved" };
}

export async function lookupEmailProvider(domain: string): Promise<EmailProviderResult> {
  try {
    const records = await resolveMx(domain);
    const ordered = records.sort((left, right) => left.priority - right.priority);
    return classifyMxRecords(ordered);
  } catch (caught) {
    try {
      return classifyMxRecords(await resolveMxOverHttps(domain));
    } catch { /* Fall through to a stable lookup status. */ }
    const code = typeof caught === "object" && caught && "code" in caught ? String(caught.code) : "";
    if (["ENODATA", "ENOTFOUND", "ENONAME", "NXDOMAIN"].includes(code)) {
      return { esp: "No MX record", category: "Unknown", mxRecords: [], status: "no_mx" };
    }
    return { esp: "Lookup failed", category: "Unknown", mxRecords: [], status: "lookup_failed" };
  }
}
