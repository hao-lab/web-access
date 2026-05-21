#!/usr/bin/env node
/**
 * Cookie Manager for headless_shell + cdp-proxy
 *
 * Supported input formats:
 * 1. Playwright storageState: { cookies: [...], origins: [...] }
 * 2. Cookie-Editor / EditThisCookie style: [ { name, value, domain, path, ... }, ... ]
 *
 * Usage:
 *   node scripts/cookie-manager.mjs import cookies.json
 *   node scripts/cookie-manager.mjs export storage-state.json
 *   node scripts/cookie-manager.mjs list
 *   node scripts/cookie-manager.mjs inject example.com session abc123
 */

import fs from 'node:fs';

const PROXY = process.env.CDP_PROXY_URL || 'http://127.0.0.1:3456';

async function httpJson(path, opts = {}) {
  const res = await fetch(`${PROXY}${path}`, opts);
  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${typeof data === 'string' ? data : JSON.stringify(data)}`);
  }
  return data;
}

function normalizeSameSite(v) {
  if (v === undefined || v === null || v === '' || v === 'unspecified') return undefined;
  const s = String(v).toLowerCase();
  if (s === 'no_restriction' || s === 'none') return 'None';
  if (s === 'lax') return 'Lax';
  if (s === 'strict') return 'Strict';
  return undefined;
}

function normalizeCookie(c) {
  const domain = c.domain || c.host_key || c.host || c.url;
  if (!domain) throw new Error(`Cookie missing domain: ${JSON.stringify(c).slice(0, 200)}`);
  if (!c.name) throw new Error(`Cookie missing name: ${JSON.stringify(c).slice(0, 200)}`);

  // Cookie-Editor may use expirationDate, Playwright uses expires.
  const expires = c.expires ?? c.expirationDate;

  return {
    name: String(c.name),
    value: String(c.value ?? ''),
    domain: String(domain).replace(/^https?:\/\//, '').split('/')[0],
    path: c.path || '/',
    expires: typeof expires === 'number' && expires > 0 ? expires : undefined,
    secure: Boolean(c.secure ?? c.is_secure ?? false),
    httpOnly: Boolean(c.httpOnly ?? c.httpOnly ?? c.is_httponly ?? false),
    sameSite: normalizeSameSite(c.sameSite ?? c.same_site ?? c.samesite),
  };
}

function loadCookiesFromFile(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  const data = JSON.parse(raw);

  // Playwright storageState
  if (Array.isArray(data.cookies)) {
    return data.cookies.map(normalizeCookie);
  }

  // Cookie-Editor / EditThisCookie array
  if (Array.isArray(data)) {
    return data.map(normalizeCookie);
  }

  throw new Error('Unsupported cookie file format. Expected Playwright storageState or Cookie-Editor JSON array.');
}

async function importCookies(filePath) {
  const cookies = loadCookiesFromFile(filePath);
  let ok = 0;
  let fail = 0;

  for (const cookie of cookies) {
    try {
      const result = await httpJson('/cookies/set', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cookie),
      });
      if (result.success) ok++;
      else {
        fail++;
        console.error(`[fail] ${cookie.domain} ${cookie.name}: ${JSON.stringify(result)}`);
      }
    } catch (e) {
      fail++;
      console.error(`[fail] ${cookie.domain} ${cookie.name}: ${e.message}`);
    }
  }

  console.log(`Imported cookies: ok=${ok}, fail=${fail}, total=${cookies.length}`);
}

async function exportCookies(outPath) {
  const data = await httpJson('/cookies/get');
  const state = {
    cookies: (data.cookies || []).map(c => ({
      name: c.name,
      value: c.value,
      domain: c.domain,
      path: c.path,
      expires: c.expires,
      httpOnly: c.httpOnly,
      secure: c.secure,
      sameSite: c.sameSite,
    })),
    origins: [],
  };
  fs.writeFileSync(outPath, JSON.stringify(state, null, 2));
  console.log(`Exported ${state.cookies.length} cookies to ${outPath}`);
}

async function listCookies() {
  const data = await httpJson('/cookies/get');
  const cookies = data.cookies || [];
  console.log(`Total cookies: ${cookies.length}`);
  for (const c of cookies) {
    console.log(`${c.domain}\t${c.name}\t${String(c.value || '').slice(0, 40)}${String(c.value || '').length > 40 ? '...' : ''}`);
  }
}

async function injectCookie(domain, name, value) {
  const cookie = { domain, name, value, path: '/', secure: true, httpOnly: false };
  const result = await httpJson('/cookies/set', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cookie),
  });
  console.log(JSON.stringify(result, null, 2));
}

const [,, cmd, ...args] = process.argv;

try {
  switch (cmd) {
    case 'import': {
      const filePath = args[0];
      if (!filePath) throw new Error('Missing cookie JSON path');
      await importCookies(filePath);
      break;
    }
    case 'export': {
      await exportCookies(args[0] || 'storage-state-export.json');
      break;
    }
    case 'list': {
      await listCookies();
      break;
    }
    case 'inject': {
      const [domain, name, value] = args;
      if (!domain || !name || value === undefined) {
        throw new Error('Usage: inject <domain> <name> <value>');
      }
      await injectCookie(domain, name, value);
      break;
    }
    default:
      console.log(`Usage:
  node scripts/cookie-manager.mjs import <cookies.json>
  node scripts/cookie-manager.mjs export [storage-state.json]
  node scripts/cookie-manager.mjs list
  node scripts/cookie-manager.mjs inject <domain> <name> <value>

Environment:
  CDP_PROXY_URL=http://127.0.0.1:3456
`);
  }
} catch (e) {
  console.error(`[error] ${e.message}`);
  process.exit(1);
}
