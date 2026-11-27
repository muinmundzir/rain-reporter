// Authoritative Firestore read for a rain report, using the same
// service-account key already configured for FCM. This is what lets the
// worker stop trusting client-submitted values: the intensity, location,
// owner, and freshness are all re-read from the report document.

const OAUTH_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FIRESTORE_SCOPE = 'https://www.googleapis.com/auth/cloud-platform';

let cachedAccessToken = null;
let cachedAccessTokenExpiresAt = 0;

function toBase64Url(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function encodeJsonBase64Url(obj) {
  return toBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
}

function pemToArrayBuffer(pem) {
  const normalized = pem.replace(/\\n/g, '\n');
  const b64 = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * Exchanges the service-account key for a Google OAuth token with the
 * Firestore scope. Cached for the token's usable lifetime.
 */
async function getFirestoreAccessToken(clientEmail, privateKeyPem, now = Date.now()) {
  if (cachedAccessToken && now < cachedAccessTokenExpiresAt) {
    return cachedAccessToken;
  }

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(privateKeyPem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const iat = Math.floor(now / 1000);
  const exp = iat + 3600;
  const header = encodeJsonBase64Url({ alg: 'RS256', typ: 'JWT' });
  const claim = encodeJsonBase64Url({
    iss: clientEmail,
    scope: FIRESTORE_SCOPE,
    aud: OAUTH_TOKEN_URL,
    iat,
    exp,
  });

  const signingInput = `${header}.${claim}`;
  const sigBuf = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  const assertion = `${signingInput}.${toBase64Url(new Uint8Array(sigBuf))}`;

  const res = await fetch(OAUTH_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`OAuth token exchange failed (${res.status}): ${errText}`);
  }
  const data = await res.json();
  cachedAccessToken = data.access_token;
  cachedAccessTokenExpiresAt =
    now + Math.max(60, (data.expires_in || 3600) - 60) * 1000;
  return cachedAccessToken;
}

// --- Firestore REST v1 value accessors -------------------------------------
function stringValue(fields, key) {
  const v = fields?.[key];
  if (!v) return null;
  if (v.stringValue != null) return v.stringValue;
  if (v.value != null) return String(v.value);
  return null;
}

function numberValue(fields, key) {
  const v = fields?.[key];
  if (!v) return null;
  if (v.integerValue != null) return Number(v.integerValue);
  if (v.doubleValue != null) return v.doubleValue;
  if (v.numberValue != null) return v.numberValue;
  if (typeof v.value === 'number') return v.value;
  return null;
}

function timestampMillis(fields, key) {
  const v = fields?.[key];
  if (!v) return null;
  if (v.timestampValue) {
    const t = Date.parse(v.timestampValue);
    if (!Number.isNaN(t)) return t;
  }
  if (typeof v.value === 'string') {
    const t = Date.parse(v.value);
    if (!Number.isNaN(t)) return t;
  }
  if (v.seconds != null) {
    return Number(v.seconds) * 1000 + Math.floor(Number(v.nanos ?? 0) / 1e6);
  }
  return null;
}

/**
 * Reads a rain report document from Firestore and returns a normalized,
 * authoritative view. Returns `{ exists: false }` when the document is missing.
 *
 * @param {{ FIREBASE_PROJECT_ID: string, FIREBASE_CLIENT_EMAIL: string, FIREBASE_PRIVATE_KEY: string }} env
 * @param {string} reportId
 * @param {{ fetchFn?: typeof fetch, getAccessToken?: (env) => Promise<string> }} [options]
 * @returns {Promise<{ exists: boolean, uid?: string, intensity?: string, note?: string|null, lat?: number|null, lng?: number|null, geohash?: string|null, expiresAtMs?: number|null }>}
 */
export async function fetchRainReport(env, reportId, options = {}) {
  const fetchFn = options.fetchFn ?? fetch;
  const token = options.getAccessToken
    ? await options.getAccessToken(env)
    : await getFirestoreAccessToken(
        env.FIREBASE_CLIENT_EMAIL,
        env.FIREBASE_PRIVATE_KEY,
      );

  const url =
    `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}` +
    `/databases/(default)/documents/reports/${encodeURIComponent(reportId)}`;
  const res = await fetchFn(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status === 404) {
    return { exists: false };
  }
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Firestore read failed (${res.status}): ${errText}`);
  }

  const body = await res.json();
  const fields = body?.fields ?? {};
  return {
    exists: true,
    uid: stringValue(fields, 'uid') ?? '',
    intensity: stringValue(fields, 'intensity') ?? '',
    note: stringValue(fields, 'note'),
    lat: numberValue(fields, 'lat'),
    lng: numberValue(fields, 'lng'),
    geohash: stringValue(fields, 'geohash'),
    expiresAtMs: timestampMillis(fields, 'expiresAt'),
  };
}
