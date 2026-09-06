import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export type Provider = 'smartlead' | 'verifier';
export function isProvider(value: unknown): value is Provider {
  return value === 'smartlead' || value === 'verifier';
}

function masterKey(raw: string) {
  if (!/^[a-fA-F0-9]{64}$/.test(raw)) throw new Error('Integration encryption is not configured.');
  return Buffer.from(raw, 'hex');
}

// AAD binds ciphertext to its provider; copying credentials between rows fails.
export function sealCredential(provider: Provider, secret: string, rawKey: string) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', masterKey(rawKey), iv);
  cipher.setAAD(Buffer.from(`prospect-integrations:v1:${provider}`));
  const ciphertext = Buffer.concat([cipher.update(secret, 'utf8'), cipher.final()]);
  return ['v1', iv.toString('base64'), cipher.getAuthTag().toString('base64'), ciphertext.toString('base64')].join('.');
}

export function openCredential(provider: Provider, envelope: string, rawKey: string) {
  const parts = envelope.split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') throw new Error('Invalid credential envelope.');
  const [, iv, tag, body] = parts;
  const decipher = createDecipheriv('aes-256-gcm', masterKey(rawKey), Buffer.from(iv, 'base64'));
  decipher.setAAD(Buffer.from(`prospect-integrations:v1:${provider}`));
  decipher.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(body, 'base64')), decipher.final()]).toString('utf8');
}

export function integrationAdmin(email: string | undefined, configured: string | undefined) {
  return !!email && (configured ?? '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean).includes(email.toLowerCase());
}

export function integrationWriteAllowed(request: Request, publicUrl: string | undefined) {
  // TLS terminates at the proxy, so Request.url can contain the internal origin.
  // Trust deployment configuration, never Host or forwarded headers supplied by callers.
  if (!publicUrl) return false;
  try {
    const expected = new URL(publicUrl);
    if (!['http:', 'https:'].includes(expected.protocol) || expected.username || expected.password
      || expected.pathname !== '/' || expected.search || expected.hash) return false;
    return request.headers.get('origin') === expected.origin
      && request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() === 'application/json';
  } catch { return false; }
}
