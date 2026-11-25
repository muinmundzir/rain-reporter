import test from 'node:test';
import assert from 'node:assert/strict';

import { createHandler } from '../src/index.mjs';

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
