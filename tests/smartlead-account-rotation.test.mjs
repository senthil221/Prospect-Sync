import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { inboxConnectionCurrent } from '../lib/integrations/inbox-connection.ts';

const migration = await readFile(new URL('../supabase/migrations/20260929173000_smartlead_account_scoped_inbox.sql', import.meta.url), 'utf8');
const route = await readFile(new URL('../app/api/integrations/route.ts', import.meta.url), 'utf8');
const panel = await readFile(new URL('../app/components/ReplyBlocklistPanel.tsx', import.meta.url), 'utf8');

test('inbox validation belongs to the current connected Smartlead generation', () => {
  const verifiedAt = '2026-09-29T10:00:00.000Z';
  assert.equal(inboxConnectionCurrent(true, 'account-a', 'account-a', verifiedAt), true);
  assert.equal(inboxConnectionCurrent(true, 'account-b', 'account-a', verifiedAt), false);
  assert.equal(inboxConnectionCurrent(true, 'account-b', 'account-b', verifiedAt), true);
  assert.equal(inboxConnectionCurrent(false, 'account-a', 'account-a', verifiedAt), false);
  assert.equal(inboxConnectionCurrent(true, 'account-a', 'account-a', null), false);
  assert.equal(inboxConnectionCurrent(true, null, 'account-a', verifiedAt), false);
  assert.equal(inboxConnectionCurrent(true, 'account-a', null, verifiedAt), false);
});

test('inbox ledgers, mappings and status are scoped to the connection generation', () => {
  assert.match(migration, /primary key\(connection_generation,provider_key\)/i);
  assert.match(migration, /foreign key\(connection_generation,provider_key\)/i);
  assert.match(migration, /primary key\(connection_generation,prefix\)/i);
  assert.match(migration, /o\.connection_generation=c\.generation/i);
  assert.match(migration, /m\.connection_generation=cc\.generation/i);
});

test('rotation is atomic, pauses sync and fences old worker actions', () => {
  const start = migration.indexOf('create function public.rotate_smartlead_connection_v1');
  const end = migration.indexOf('create function public.disconnect_smartlead_connection_v1', start);
  const rotation = migration.slice(start, end);
  assert.ok(start >= 0 && end > start);
  const settingsLock = rotation.indexOf('smartlead_inbox_settings where singleton for update');
  const connectionLock = rotation.indexOf("provider='smartlead' and attempt_token=p_attempt_token for update");
  const actionLock = rotation.indexOf("status in ('pending','applying') order by id for update");
  assert.ok(settingsLock >= 0 && connectionLock > settingsLock && actionLock > connectionLock);
  assert.match(rotation, /enabled=false,verified_generation=null/);
  assert.match(rotation, /last_error_code='connection_changed'/);
  assert.match(route, /rpc\('rotate_smartlead_connection_v1'/);
  assert.match(route, /rpc\('disconnect_smartlead_connection_v1'/);
});

test('category behavior is discovered per account and uncertain IDs fail closed', () => {
  assert.match(migration, /normalized_name.*behavior/s);
  assert.match(migration, /when 'out of office' then 'ignore'/);
  assert.match(migration, /when 'not the right fit' then 'email_and_domain'/);
  assert.doesNotMatch(migration, /v_category\s+in\s*\(/i);
  assert.doesNotMatch(migration, /v_category\s*=\s*120097/i);
  assert.match(route, /readSmartleadCategories/);
  assert.match(route, /confirm_smartlead_inbox_contract_v2/);
});

test('Smartlead credential rotation is managed beside reply sync, not duplicated in Integrations', async () => {
  const integrations = await readFile(new URL('../app/components/IntegrationsPanel.tsx', import.meta.url), 'utf8');
  assert.match(panel, /Smartlead API key/);
  assert.match(panel, /Change API key/);
  assert.match(panel, /Validate this Smartlead account/);
  assert.match(integrations, /provider !== 'smartlead' && <form/);
  assert.match(integrations, /Manage Smartlead connection & replies/);
});
