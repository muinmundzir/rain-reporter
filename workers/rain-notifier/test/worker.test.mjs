import test from 'node:test';
import assert from 'node:assert/strict';

import { createHandler } from '../src/index.mjs';
import { verifyFirebaseIdToken, resetJwksCacheForTests } from '../src/firebase_auth.mjs';

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

test('returns 404 for unknown path and 405 for non-POST', async () => {
  const handler = createHandler({
    verifyToken: async () => ({ uid: 'u1' }),
    sendFcm: async () => {},
  });

  const res404 = await handler.fetch(makeRequest({}, { path: '/other' }), baseEnv);
  assert.equal(res404.status, 404);

  const res405 = await handler.fetch(makeRequest(undefined, { method: 'GET' }), baseEnv);
  assert.equal(res405.status, 405);
});

test('returns 401 when Authorization header is missing or token verification fails', async () => {
  let fcmCalled = false;
  const handler = createHandler({
    verifyToken: async (token) => {
      if (token !== 'good-token') throw new Error('invalid token');
      return { uid: 'u1' };
    },
    sendFcm: async () => {
      fcmCalled = true;
    },
  });

  const missingAuth = await handler.fetch(
    makeRequest({ geohash5: 'qqv3r', intensity: 'heavy', lat: -6.9175, lng: 107.6191 }, { token: null }),
    baseEnv,
  );
  assert.equal(missingAuth.status, 401);

  const badAuth = await handler.fetch(
    makeRequest({ geohash5: 'qqv3r', intensity: 'heavy', lat: -6.9175, lng: 107.6191 }, { token: 'bad' }),
    baseEnv,
  );
  assert.equal(badAuth.status, 401);
  assert.equal(fcmCalled, false);
});

test('returns 400 for invalid JSON, non-heavy/storm intensity, invalid geohash5, or bad coords', async () => {
  const handler = createHandler({
    verifyToken: async () => ({ uid: 'u1' }),
    sendFcm: async () => {},
  });

  assert.equal((await handler.fetch(makeRequest('not-json'), baseEnv)).status, 400);
  assert.equal(
    (await handler.fetch(makeRequest({ geohash5: 'qqv3r', intensity: 'light', lat: -6.9, lng: 107.6 }), baseEnv)).status,
    400,
  );
  assert.equal(
    (await handler.fetch(makeRequest({ geohash5: 'qqv3r', intensity: 'moderate', lat: -6.9, lng: 107.6 }), baseEnv)).status,
    400,
  );
  assert.equal(
    (await handler.fetch(makeRequest({ geohash5: 'qqv3r', intensity: 'stopped', lat: -6.9, lng: 107.6 }), baseEnv)).status,
    400,
  );
  assert.equal(
    (await handler.fetch(makeRequest({ geohash5: 'BAD!', intensity: 'heavy', lat: -6.9, lng: 107.6 }), baseEnv)).status,
    400,
  );
  assert.equal(
    (await handler.fetch(makeRequest({ geohash5: 'qqv3r', intensity: 'heavy', lat: 95, lng: 107.6 }), baseEnv)).status,
    400,
  );
});

test('sends FCM topic message for valid heavy and storm reports and truncates long note to 140 chars', async () => {
  const sent = [];
  const handler = createHandler({
    verifyToken: async () => ({ uid: 'u1' }),
    sendFcm: async (env, payload) => {
      sent.push(payload);
    },
  });

  const longNote = 'x'.repeat(200);
  const res1 = await handler.fetch(
    makeRequest({ geohash5: 'qqv3r', intensity: 'heavy', lat: -6.9175, lng: 107.6191, note: longNote }),
    baseEnv,
  );
  assert.equal(res1.status, 200);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].topic, 'rain_qqv3r');
  assert.equal(sent[0].title, 'Heavy Rain Nearby');
  assert.equal(sent[0].body.length, 140);
  assert.deepEqual(sent[0].data, {
    intensity: 'heavy',
    lat: '-6.9175',
    lng: '107.6191',
    geohash5: 'qqv3r',
  });

  const res2 = await handler.fetch(
    makeRequest({ geohash5: 'qqv3r', intensity: 'storm', lat: -6.9175, lng: 107.6191 }),
    baseEnv,
  );
  assert.equal(res2.status, 200);
  assert.equal(sent[1].title, 'Storm Nearby');
  assert.equal(sent[1].body, 'Reported in your area — tap to view map');
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
