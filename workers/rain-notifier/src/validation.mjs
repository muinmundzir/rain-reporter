export const ALLOWED_INTENSITIES = new Set(['heavy', 'storm']);

// Firestore document ids are safe for a REST path segment. Restrict the charset
// so a caller can't smuggle a `/` or query string into the Firestore URL.
const REPORT_ID_RE = /^[\w.-]{1,128}$/;

/**
 * Extracts and validates the `reportId` from the incoming notification payload.
 *
 * The worker no longer trusts any client-supplied rain data (intensity,
 * location, note): it re-reads the authoritative report document from
 * Firestore keyed by this id. So the only thing we accept from the client is
 * the id itself.
 *
 * @param {unknown} raw
 * @returns {{ ok: true, value: { reportId: string } } | { ok: false, error: string }}
 */
export function extractReportId(raw) {
  if (!raw || typeof raw !== 'object') {
    return { ok: false, error: 'Body must be a JSON object' };
  }

  const { reportId } = raw;
  if (typeof reportId !== 'string' || !REPORT_ID_RE.test(reportId)) {
    return { ok: false, error: 'Missing or invalid reportId' };
  }

  return { ok: true, value: { reportId } };
}
