import test from 'node:test';
import assert from 'node:assert/strict';

import { createHandler } from '../src/index.mjs';
import { verifyFirebaseIdToken, resetJwksCacheForTests } from '../src/firebase_auth.mjs';
import { encodeGeohash } from '../src/geohash.mjs';

const baseEnv = {
  FIREBASE_PROJECT_ID: 'rain-reporter-bdg',
  FIREBASE_CLIENT_EMAIL: 'test@rain-reporter-bdg.iam.gserviceaccount.com',
  FIREBASE_PRIVATE_KEY: 'unused-in-mock',
};

function makeRequest(body, { method = 'POST', path = '/notify-rain', token = 'valid-token' } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (token !== null) {
    headers.authorization = `Bearer ${token}`;
  }
  return new Request(`https://rain-notifier.example.workers.dev${path}`, {
    method,
    headers,
    body: method === 'GET' ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
}

// A fake authoritative report document, mirroring the shape fetchRainReport
// returns. Defaults to an active heavy-rain report near Bandung.
function activeDoc({
  uid = 'u1',
  intensity = 'heavy',
  lat = -6.9175,
  lng = 107.6191,
  note = null,
  ageMs = 0,
} = {}) {
  return {
    exists: true,
    uid,
    intensity,
    note,
    lat,
    lng,
    geohash: 'qqv3r',
    expiresAtMs: Date.now() + 30 * 60 * 1000 - ageMs,
  };
}

function fakeVerify(uid = 'u1') {
  return async () => ({ uid });
}

test('returns 404 for unknown path and 405 for non-POST', async () => {
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async () => {},
    fetchReport: async () => ({ exists: false }),
  });

  const res404 = await handler.fetch(makeRequest({ reportId: 'r1' }, { path: '/other' }), baseEnv);
  assert.equal(res404.status, 404);

  const res405 = await handler.fetch(makeRequest(undefined, { method: 'GET' }), baseEnv);
  assert.equal(res405.status, 405);
});

test('returns 401 when Authorization header is missing or token verification fails', async () => {
  let fcmCalled = false;
  let reportCalled = false;
  const handler = createHandler({
    verifyToken: async (token) => {
      if (token !== 'good-token') throw new Error('invalid token');
      return { uid: 'u1' };
    },
    sendFcm: async () => {
      fcmCalled = true;
    },
    fetchReport: async () => {
      reportCalled = true;
      return activeDoc();
    },
  });

  const missingAuth = await handler.fetch(
    makeRequest({ reportId: 'r1' }, { token: null }),
    baseEnv,
  );
  assert.equal(missingAuth.status, 401);

  const badAuth = await handler.fetch(
    makeRequest({ reportId: 'r1' }, { token: 'bad' }),
    baseEnv,
  );
  assert.equal(badAuth.status, 401);
  assert.equal(fcmCalled, false);
  assert.equal(reportCalled, false);
});

test('returns 400 for invalid JSON, a missing reportId, or a malformed reportId', async () => {
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async () => {},
    fetchReport: async () => activeDoc(),
  });

  // Not a JSON object.
  assert.equal((await handler.fetch(makeRequest('not-json'), baseEnv)).status, 400);
  // No reportId.
  assert.equal((await handler.fetch(makeRequest({}), baseEnv)).status, 400);
  // reportId is not a string.
  assert.equal((await handler.fetch(makeRequest({ reportId: 123 }), baseEnv)).status, 400);
  // reportId tries to smuggle a path segment into the Firestore URL.
  assert.equal((await handler.fetch(makeRequest({ reportId: 'a/../b' }), baseEnv)).status, 400);
});

test('returns 404 when the report does not exist', async () => {
  let fcmCalled = false;
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async () => {
      fcmCalled = true;
    },
    fetchReport: async () => ({ exists: false }),
  });

  const res = await handler.fetch(makeRequest({ reportId: 'missing' }), baseEnv);
  assert.equal(res.status, 404);
  assert.equal(fcmCalled, false);
});

test('returns 403 when the report is owned by a different user', async () => {
  let fcmCalled = false;
  const handler = createHandler({
    verifyToken: fakeVerify('attacker'),
    sendFcm: async () => {
      fcmCalled = true;
    },
    fetchReport: async () => activeDoc({ uid: 'owner', intensity: 'storm' }),
  });

  const res = await handler.fetch(makeRequest({ reportId: 'r1' }), baseEnv);
  assert.equal(res.status, 403);
  assert.equal(fcmCalled, false);
});

test('returns 410 when the report is no longer active', async () => {
  let fcmCalled = false;
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async () => {
      fcmCalled = true;
    },
    fetchReport: async () => activeDoc({ ageMs: 31 * 60 * 1000 }),
  });

  const res = await handler.fetch(makeRequest({ reportId: 'r1' }), baseEnv);
  assert.equal(res.status, 410);
  assert.equal(fcmCalled, false);
});

test('does not alert for an authoritative intensity that is not heavy/storm', async () => {
  let fcmCalled = false;
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async () => {
      fcmCalled = true;
    },
    fetchReport: async () => activeDoc({ intensity: 'moderate' }),
  });

  const res = await handler.fetch(makeRequest({ reportId: 'r1' }), baseEnv);
  assert.equal(res.status, 400);
  assert.equal(fcmCalled, false);
});

test('derives the FCM topic from the document, ignoring client-supplied fields', async () => {
  const sent = [];
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async (env, payload) => sent.push(payload),
    // The client forges storm + a far-away cell + a fake note; the document
    // says heavy, Bandung, real note. The document must win.
    fetchReport: async () => activeDoc({ intensity: 'heavy', note: 'real note' }),
  });

  const res = await handler.fetch(
    makeRequest({
      reportId: 'r1',
      geohash5: 'zzzzz', // forged client value — must be ignored
      intensity: 'storm', // forged client value — must be ignored
      lat: 89,
      lng: 170,
      note: 'forged',
    }),
    baseEnv,
  );
  assert.equal(res.status, 200);
  assert.equal(sent.length, 1);
  // Topic + data come from the authoritative document location (-6.9175,107.6191).
  assert.equal(sent[0].topic, `rain_${encodeGeohash(-6.9175, 107.6191, 5)}`);
  assert.equal(sent[0].topic, 'rain_qqu88');
  assert.equal(sent[0].data.intensity, 'heavy');
  assert.equal(sent[0].data.geohash5, 'qqu88');
  assert.equal(sent[0].body, 'real note');
});

test('sends FCM for valid heavy and storm reports, truncating the document note to 140 chars', async () => {
  const sent = [];
  const handler = createHandler({
    verifyToken: fakeVerify(),
    sendFcm: async (env, payload) => sent.push(payload),
    fetchReport: async (_env, reportId) =>
      reportId === 'stormy' ? activeDoc({ intensity: 'storm' }) : activeDoc({ note: 'x'.repeat(200) }),
  });

  const res1 = await handler.fetch(makeRequest({ reportId: 'heavy' }), baseEnv);
  assert.equal(res1.status, 200);
  assert.equal(sent[0].title, 'Heavy Rain Nearby');
  assert.equal(sent[0].body.length, 140);
  assert.deepEqual(sent[0].data, {
    intensity: 'heavy',
    lat: '-6.9175',
    lng: '107.6191',
    geohash5: 'qqu88',
  });

  const res2 = await handler.fetch(makeRequest({ reportId: 'stormy' }), baseEnv);
  assert.equal(res2.status, 200);
  assert.equal(sent[1].title, 'Storm Nearby');
  assert.equal(sent[1].body, 'Reported in your area — tap to view map');
});

test('geohash encoding matches the Dart reference values', () => {
  assert.equal(encodeGeohash(-6.9175, 107.6191, 5), 'qqu88');
  assert.equal(encodeGeohash(-6.2, 106.8166, 5), 'qqguw');
  // Default precision (7) is also supported.
  assert.equal(encodeGeohash(-6.9175, 107.6191, 7).length, 7);
});

async function makeSignedJwt(privateKey, header, payload) {
  const b64u = (obj) =>
    Buffer.from(JSON.stringify(obj)).toString('base64url');
  const input = `${b64u(header)}.${b64u(payload)}`;
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${Buffer.from(sig).toString('base64url')}`;
}

test('verifyFirebaseIdToken validates RS256 signature, claims, and refreshes JWKS on kid rotation', async () => {
  resetJwksCacheForTests();
  const keyPair1 = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const keyPair2 = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const jwk1 = { ...(await crypto.subtle.exportKey('jwk', keyPair1.publicKey)), kid: 'k1' };
  const jwk2 = { ...(await crypto.subtle.exportKey('jwk', keyPair2.publicKey)), kid: 'k2' };

  let fetchCount = 0;
  const fetchJwks = async () => {
    fetchCount++;
    return fetchCount === 1 ? [jwk1] : [jwk1, jwk2];
  };

  const now = Math.floor(Date.now() / 1000);
  const validToken1 = await makeSignedJwt(
    keyPair1.privateKey,
    { alg: 'RS256', kid: 'k1' },
    { aud: 'rain-reporter-bdg', iss: 'https://securetoken.google.com/rain-reporter-bdg', exp: now + 300, sub: 'uid-1' },
  );
  const verified1 = await verifyFirebaseIdToken(validToken1, 'rain-reporter-bdg', { fetchJwks });
  assert.equal(verified1.uid, 'uid-1');

  // Expired token rejected
  const expiredToken = await makeSignedJwt(
    keyPair1.privateKey,
    { alg: 'RS256', kid: 'k1' },
    { aud: 'rain-reporter-bdg', iss: 'https://securetoken.google.com/rain-reporter-bdg', exp: now - 10, sub: 'uid-1' },
  );
  await assert.rejects(() => verifyFirebaseIdToken(expiredToken, 'rain-reporter-bdg', { fetchJwks }));

  // Wrong aud rejected
  const wrongAud = await makeSignedJwt(
    keyPair1.privateKey,
    { alg: 'RS256', kid: 'k1' },
    { aud: 'other-project', iss: 'https://securetoken.google.com/rain-reporter-bdg', exp: now + 300, sub: 'uid-1' },
  );
  await assert.rejects(() => verifyFirebaseIdToken(wrongAud, 'rain-reporter-bdg', { fetchJwks }));

  // Rotated key k2 triggers JWKS refresh and succeeds
  const rotatedToken = await makeSignedJwt(
    keyPair2.privateKey,
    { alg: 'RS256', kid: 'k2' },
    { aud: 'rain-reporter-bdg', iss: 'https://securetoken.google.com/rain-reporter-bdg', exp: now + 300, sub: 'uid-2' },
  );
  const verified2 = await verifyFirebaseIdToken(rotatedToken, 'rain-reporter-bdg', { fetchJwks });
  assert.equal(verified2.uid, 'uid-2');
  assert.equal(fetchCount, 2);
});
