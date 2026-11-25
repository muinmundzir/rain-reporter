const GEOHASH5_RE = /^[0-9b-hjkmnp-z]{5}$/;
const ALLOWED_INTENSITIES = new Set(['heavy', 'storm']);

/**
 * Validates and normalizes the incoming rain notification payload.
 * @param {unknown} raw
 * @returns {{ ok: true, value: { geohash5: string, intensity: 'heavy' | 'storm', lat: number, lng: number, note: string | null } } | { ok: false, error: string }}
 */
export function validateRainPayload(raw) {
  if (!raw || typeof raw !== 'object') {
    return { ok: false, error: 'Body must be a JSON object' };
  }

  const { geohash5, intensity, lat, lng, note } = raw;

  if (typeof intensity !== 'string' || !ALLOWED_INTENSITIES.has(intensity)) {
    return { ok: false, error: 'Only heavy and storm intensities trigger alerts' };
  }
  if (typeof geohash5 !== 'string' || !GEOHASH5_RE.test(geohash5)) {
    return { ok: false, error: 'Invalid 5-char geohash' };
  }
  if (typeof lat !== 'number' || !Number.isFinite(lat) || lat < -90 || lat > 90) {
    return { ok: false, error: 'Invalid lat' };
  }
  if (typeof lng !== 'number' || !Number.isFinite(lng) || lng < -180 || lng > 180) {
    return { ok: false, error: 'Invalid lng' };
  }

  let cleanNote = null;
  if (typeof note === 'string') {
    const trimmed = note.trim();
    if (trimmed.length > 0) {
      cleanNote = trimmed.slice(0, 140);
    }
  }

  return {
    ok: true,
    value: {
      geohash5,
      intensity: /** @type {'heavy' | 'storm'} */ (intensity),
      lat,
      lng,
      note: cleanNote,
    },
  };
}
