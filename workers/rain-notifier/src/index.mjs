import { verifyFirebaseIdToken } from './firebase_auth.mjs';
import { sendFcmTopicMessage } from './fcm.mjs';
import { validateRainPayload } from './validation.mjs';

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export function createHandler({
  verifyToken = verifyFirebaseIdToken,
  sendFcm = sendFcmTopicMessage,
} = {}) {
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      if (url.pathname !== '/notify-rain') {
        return jsonResponse(404, { error: 'Not found' });
      }
      if (request.method !== 'POST') {
        return jsonResponse(405, { error: 'Method not allowed' });
      }

      const authHeader = request.headers.get('authorization') || '';
      const match = authHeader.match(/^Bearer\s+(.+)$/i);
      if (!match) {
        return jsonResponse(401, { error: 'Missing Bearer token' });
      }

      try {
        await verifyToken(match[1].trim(), env.FIREBASE_PROJECT_ID);
      } catch {
        return jsonResponse(401, { error: 'Invalid Firebase ID token' });
      }

      let rawBody;
      try {
        rawBody = await request.json();
      } catch {
        return jsonResponse(400, { error: 'Invalid JSON body' });
      }

      const parsed = validateRainPayload(rawBody);
      if (!parsed.ok) {
        return jsonResponse(400, { error: parsed.error });
      }

      const { geohash5, intensity, lat, lng, note } = parsed.value;
      const title = intensity === 'storm' ? 'Storm Nearby' : 'Heavy Rain Nearby';
      const body = note ?? 'Reported in your area — tap to view map';

      try {
        await sendFcm(env, {
          topic: `rain_${geohash5}`,
          title,
          body,
          data: {
            intensity,
            lat: String(lat),
            lng: String(lng),
            geohash5,
          },
        });
      } catch (err) {
        return jsonResponse(502, {
          error: 'Failed to send FCM notification',
          detail: err instanceof Error ? err.message : String(err),
        });
      }

      return jsonResponse(200, { ok: true, topic: `rain_${geohash5}` });
    },
  };
}

export default createHandler();
