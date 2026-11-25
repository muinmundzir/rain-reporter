const JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

let cachedJwks = null;
let cachedJwksExpiresAt = 0;
let lastForcedRefreshAt = 0;

export function resetJwksCacheForTests() {
  cachedJwks = null;
  cachedJwksExpiresAt = 0;
  lastForcedRefreshAt = 0;
}

function base64UrlToUint8Array(input) {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/') +
    '==='.slice((input.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function decodeJsonSegment(segment) {
  const bytes = base64UrlToUint8Array(segment);
  return JSON.parse(new TextDecoder().decode(bytes));
}

async function defaultFetchJwks() {
  const res = await fetch(JWKS_URL);
  if (!res.ok) {
    throw new Error(`Failed to fetch Firebase JWKS (${res.status})`);
  }
  const cacheControl = res.headers.get('cache-control') || '';
  const maxAgeMatch = cacheControl.match(/max-age=(\d+)/);
  const maxAgeSeconds = maxAgeMatch ? Number(maxAgeMatch[1]) : 3600;
  const data = await res.json();
  return { keys: data.keys || [], maxAgeSeconds };
}

async function getJwks({ fetchJwks, forceRefresh = false } = {}) {
  const now = Date.now();
  if (!forceRefresh && cachedJwks && now < cachedJwksExpiresAt) {
    return cachedJwks;
  }
  if (forceRefresh && now - lastForcedRefreshAt < 60_000 && cachedJwks) {
    return cachedJwks;
  }

  if (forceRefresh) {
    lastForcedRefreshAt = now;
  }

  if (fetchJwks) {
    const keys = await fetchJwks();
    cachedJwks = keys;
    cachedJwksExpiresAt = now + 3600 * 1000;
    return cachedJwks;
  }

  const { keys, maxAgeSeconds } = await defaultFetchJwks();
  cachedJwks = keys;
  cachedJwksExpiresAt = now + maxAgeSeconds * 1000;
  return cachedJwks;
}

/**
 * Verifies a Firebase Auth ID token (RS256) against Google's SecureToken JWKS.
 * @param {string} token
 * @param {string} projectId
 * @param {{ fetchJwks?: () => Promise<Array<JsonWebKey & { kid?: string }>> }} [options]
 * @returns {Promise<{ uid: string }>}
 */
export async function verifyFirebaseIdToken(token, projectId, options = {}) {
  if (!projectId) {
    throw new Error('Missing projectId');
  }
  const parts = token.split('.');
  if (parts.length !== 3) {
    throw new Error('Malformed JWT');
  }

  const [headerB64, payloadB64, signatureB64] = parts;
  const header = decodeJsonSegment(headerB64);
  const payload = decodeJsonSegment(payloadB64);

  if (header.alg !== 'RS256' || !header.kid) {
    throw new Error('Unsupported JWT algorithm or missing kid');
  }

  const nowSec = Math.floor(Date.now() / 1000);
  if (payload.aud !== projectId) {
    throw new Error('Invalid aud');
  }
  if (payload.iss !== `https://securetoken.google.com/${projectId}`) {
    throw new Error('Invalid iss');
  }
  if (typeof payload.exp !== 'number' || payload.exp <= nowSec) {
    throw new Error('Token expired');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Missing sub');
  }

  let keys = await getJwks({ fetchJwks: options.fetchJwks });
  let jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    // Key may have rotated while JWKS was cached; force one refresh.
    keys = await getJwks({ fetchJwks: options.fetchJwks, forceRefresh: true });
    jwk = keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) {
    throw new Error('Signing key not found');
  }

  const cryptoKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );

  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const signature = base64UrlToUint8Array(signatureB64);
  const valid = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    signature,
    signingInput,
  );
  if (!valid) {
    throw new Error('Invalid JWT signature');
  }

  return { uid: payload.sub };
}
