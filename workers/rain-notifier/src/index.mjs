import { verifyFirebaseIdToken } from './firebase_auth.mjs';
import { sendFcmTopicMessage } from './fcm.mjs';
import { extractReportId, ALLOWED_INTENSITIES } from './validation.mjs';
import { fetchRainReport } from './firestore.mjs';
import { encodeGeohash } from './geohash.mjs';

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export function createHandler({
  verifyToken = verifyFirebaseIdToken,
  sendFcm = sendFcmTopicMessage,
  fetchReport = fetchRainReport,
  now = () => Date.now(),
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

      let auth;
      try {
        auth = await verifyToken(match[1].trim(), env.FIREBASE_PROJECT_ID);
      } catch {
        return jsonResponse(401, { error: 'Invalid Firebase ID token' });
      }

      let rawBody;
      try {
        rawBody = await request.json();
      } catch {
        return jsonResponse(400, { error: 'Invalid JSON body' });
      }

      // The client only supplies the report id. Every other value (intensity,
      // location, note, freshness) is re-read authoritatively from Firestore
      // below, so a spoofed payload can no longer trigger a fake alert.
      const parsed = extractReportId(rawBody);
      if (!parsed.ok) {
        return jsonResponse(400, { error: parsed.error });
      }
      const { reportId } = parsed.value;

      let report;
      try {
        report = await fetchReport(env, reportId);
      } catch (err) {
        return jsonResponse(502, {
          error: 'Failed to verify report',
          detail: err instanceof Error ? err.message : String(err),
        });
      }

      if (!report || !report.exists) {
        return jsonResponse(404, { error: 'Report not found' });
      }
      // Only the author of a report may trigger alerts for it.
      if (report.uid !== auth.uid) {
        return jsonResponse(403, { error: 'Report not owned by this user' });
      }

      const expiresAtMs = report.expiresAtMs;
      if (expiresAtMs == null || expiresAtMs <= now()) {
        return jsonResponse(410, { error: 'Report is no longer active' });
      }

      const intensity = report.intensity;
      if (typeof intensity !== 'string' || !ALLOWED_INTENSITIES.has(intensity)) {
        return jsonResponse(400, {
          error: 'Only heavy and storm reports trigger alerts',
        });
      }

      const lat = report.lat;
      const lng = report.lng;
      if (
        typeof lat !== 'number' ||
        typeof lng !== 'number' ||
        !Number.isFinite(lat) ||
        !Number.isFinite(lng) ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180
      ) {
        return jsonResponse(400, { error: 'Report has no valid location' });
      }

      // Derive the FCM topic cell from the authoritative location, at the same
      // precision (5) subscribers use when computing their own cell.
      const geohash5 = encodeGeohash(lat, lng, 5);
      const note =
        typeof report.note === 'string' ? report.note.slice(0, 140).trim() : '';
      const title = intensity === 'storm' ? 'Storm Nearby' : 'Heavy Rain Nearby';
      const body = note.length > 0 ? note : 'Reported in your area — tap to view map';

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
