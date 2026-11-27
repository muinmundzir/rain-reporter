// Standard base32 geohash encoder, ported from lib/domain/location_privacy.dart
// (LocationPrivacy.encodeGeohash) so the worker can authoritatively derive the
// FCM topic cell from a report's real location.

const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/**
 * Encode a geographic point to a base32 geohash of the given precision.
 * Mirrors the Dart encoder exactly (same bit order, same base32 alphabet).
 *
 * @param {number} lat latitude in degrees, -90..90
 * @param {number} lng longitude in degrees, -180..180
 * @param {number} [precision=5] number of geohash characters
 * @returns {string}
 */
export function encodeGeohash(lat, lng, precision = 5) {
  let minLat = -90.0,
    maxLat = 90.0;
  let minLng = -180.0,
    maxLng = 180.0;
  let isEven = true; // even bits split longitude
  let bit = 0;
  let ch = 0;
  let out = '';

  while (out.length < precision) {
    if (isEven) {
      const mid = (minLng + maxLng) / 2;
      if (lng >= mid) {
        ch |= 1 << (4 - bit);
        minLng = mid;
      } else {
        maxLng = mid;
      }
    } else {
      const mid = (minLat + maxLat) / 2;
      if (lat >= mid) {
        ch |= 1 << (4 - bit);
        minLat = mid;
      } else {
        maxLat = mid;
      }
    }
    isEven = !isEven;
    if (bit < 4) {
      bit++;
    } else {
      out += BASE32[ch];
      bit = 0;
      ch = 0;
    }
  }
  return out;
}
