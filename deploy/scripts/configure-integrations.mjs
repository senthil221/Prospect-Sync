// Run inside a network-disabled Node container with /opt/prospect/deploy mounted
// at /deployment. Never emits credentials or touches backup settings.
import fs from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';

const file = '/deployment/.env';
const admin = process.argv[2];
if (!admin || !/^[a-zA-Z0-9_.+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(admin)) throw new Error('Supply the approved administrator email.');
const stat = fs.lstatSync(file);
if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Expected a regular deployment environment file.');
let text = fs.readFileSync(file, 'utf8');
function read(name) {
  const matches = [...text.matchAll(new RegExp(`^${name}=(.*)$`, 'gm'))];
  if (matches.length > 1) throw new Error(`Duplicate configuration: ${name}`);
  return (matches[0]?.[1] ?? '').trim().replace(/^(["'])(.*)\1$/, '$2');
}
if (!read('ALLOWED_USER_EMAILS').toLowerCase().split(',').map(s => s.trim()).includes(admin.toLowerCase())) throw new Error('Administrator is not in the existing application login allowlist; no settings changed.');
const existing = read('INTEGRATION_ENCRYPTION_KEY');
if (existing && !/^[a-fA-F0-9]{64}$/.test(existing)) throw new Error('Existing encryption key is malformed; no settings changed.');
function set(name, value) {
  const line = `${name}=${value}`;
  const regex = new RegExp(`^${name}=.*$`, 'm');
  text = regex.test(text) ? text.replace(regex, line) : text.replace(/\s*$/, '') + `\n${line}\n`;
}
set('INTEGRATION_ADMIN_EMAILS', admin.toLowerCase());
set('INTEGRATION_ENCRYPTION_KEY', existing || randomBytes(32).toString('hex'));
const temporary = `/deployment/.integration-env-${randomUUID()}`;
try {
  fs.writeFileSync(temporary, text, { mode: 0o600, flag: 'wx' });
  fs.chownSync(temporary, stat.uid, stat.gid);
  fs.renameSync(temporary, file);
} finally { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); }
console.log('Integration administrator and encryption configuration prepared. No provider credentials configured.');
