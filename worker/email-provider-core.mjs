// MX-record classification: which provider receives a domain's email, and
// whether a secure email gateway (SEG) sits in front of it.
//
// Plain JavaScript with no Node imports, so the ICP worker (which scans MX
// records continuously), the dashboard's scan route (lib/email-provider.ts)
// and the ESP filter picker all read the same list.

const suffix = (...values) => (host) => values.some((value) => host === value || host.endsWith(`.${value}`));
const includes = (...values) => (host) => values.some((value) => host.includes(value));

// SEG signatures intentionally come first. A protected domain may publish its
// downstream mailbox provider as a lower-priority fallback MX record.
const providerSignatures = [
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

// What a scan can record: every named provider, plus the three outcomes that
// are not a provider. The ESP filter offers exactly these.
export const ESP_PROVIDERS = providerSignatures.map(({ name, category }) => ({ name, category }));
export const ESP_OUTCOMES = ["Custom / unknown", "No MX record", "Lookup failed"];

function normalizeMxHost(value) {
  return value.trim().toLowerCase().replace(/\.$/, "");
}

export function parseDnsOverHttpsMx(payload) {
  if (!payload || typeof payload !== "object") throw new Error("Invalid DNS-over-HTTPS response.");
  const status = Number(payload.Status);
  if (status === 3) return [];
  if (status !== 0) throw new Error(`DNS-over-HTTPS lookup failed with status ${status}.`);
  if (!Array.isArray(payload.Answer)) return [];
  return payload.Answer.flatMap((record) => {
    if (!record || typeof record !== "object") return [];
    if (Number(record.type) !== 15 || typeof record.data !== "string") return [];
    const match = record.data.trim().match(/^(\d+)\s+(.+)$/);
    return match ? [{ priority: Number(match[1]), exchange: normalizeMxHost(match[2]) }] : [];
  }).sort((left, right) => left.priority - right.priority);
}

export function classifyMxRecords(records) {
  const mxRecords = [...new Set(records.map((record) => normalizeMxHost(typeof record === "string" ? record : record.exchange)).filter(Boolean))];
  if (!mxRecords.length) return { esp: "No MX record", category: "Unknown", mxRecords, status: "no_mx" };

  for (const signature of providerSignatures) {
    if (mxRecords.some(signature.matches)) {
      return { esp: signature.name, category: signature.category, mxRecords, status: "resolved" };
    }
  }

  return { esp: "Custom / unknown", category: "Unknown", mxRecords, status: "resolved" };
}

async function resolveMxOverHttps(domain, fetchImpl) {
  const endpoint = new URL("https://cloudflare-dns.com/dns-query");
  endpoint.searchParams.set("name", domain);
  endpoint.searchParams.set("type", "MX");
  const response = await fetchImpl(endpoint, {
    headers: { accept: "application/dns-json" },
    signal: AbortSignal.timeout(8_000),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`DNS-over-HTTPS request failed with HTTP ${response.status}.`);
  return parseDnsOverHttpsMx(await response.json());
}

// resolveMx is node:dns/promises' - passed in so this module stays importable
// from the browser bundle.
export async function lookupEmailProvider(domain, { resolveMx, fetchImpl = fetch }) {
  try {
    const records = await resolveMx(domain);
    const ordered = records.sort((left, right) => left.priority - right.priority);
    return classifyMxRecords(ordered);
  } catch (caught) {
    try {
      return classifyMxRecords(await resolveMxOverHttps(domain, fetchImpl));
    } catch { /* Fall through to a stable lookup status. */ }
    const code = typeof caught === "object" && caught && "code" in caught ? String(caught.code) : "";
    if (["ENODATA", "ENOTFOUND", "ENONAME", "NXDOMAIN"].includes(code)) {
      return { esp: "No MX record", category: "Unknown", mxRecords: [], status: "no_mx" };
    }
    return { esp: "Lookup failed", category: "Unknown", mxRecords: [], status: "lookup_failed" };
  }
}
