/**
 * Canonical device-list bytes (multi-device spec §3, Phase 2 T2).
 *
 * The signed device list `{ userId, version, devices: [...] }` has exactly ONE
 * byte form: JSON with no whitespace, `userId` and `version` first, device
 * keys sorted (addedAt, deviceId, name?, platform, revokedAt?), devices in
 * strictly ascending deviceId order, integers only for version/timestamps,
 * control characters rejected, `name` NFC-normalized and length-capped. The
 * DAK signature and `listHash` are computed over these bytes VERBATIM, and
 * the bytes travel and are stored as OPAQUE BASE64 (§3 transport rule).
 *
 * The parser enforces falsification 23: after structural validation it
 * RE-ENCODES canonically and compares byte-for-byte with the input, so every
 * liberal JSON form the writer could never emit — duplicate keys (JSON.parse
 * keeps the last, shortening the re-encode), whitespace, reordered keys,
 * `1.0`/`1e3` numbers, `\u0041` escapes — is rejected AT PARSE.
 *
 * MIRRORED byte-for-byte by the client writer/parser in
 * frontend/lib/services/device_list/device_list_canonical.dart — change the
 * two together or not at all. String escaping is deliberately hand-rolled
 * (only `"` and `\`; control characters are rejected upstream) because
 * JSON.stringify and Dart's jsonEncode disagree on optional escapes.
 *
 * The one asymmetry: NFC normalization of `name` is checked HERE only — the
 * server is the storage gate, and Dart core ships no normalizer. It is
 * display hygiene, not a signature-ambiguity risk: signatures bind the exact
 * bytes, and the byte-exact rule already rejects every re-encoding.
 */

export const DEVICE_NAME_MAX_LENGTH = 64;
export const DEVICE_PLATFORM_MAX_LENGTH = 32;
export const DEVICE_LIST_MAX_ENTRIES = 64;

export interface DeviceListEntry {
  deviceId: number;
  platform: string;
  /** Milliseconds since epoch. */
  addedAt: number;
  name?: string;
  /** Milliseconds since epoch. */
  revokedAt?: number;
}

export interface ParsedDeviceList {
  userId: number;
  version: number;
  devices: DeviceListEntry[];
}

/** Every malformed canonical is a rejection with a stable reason code. */
export class CanonicalDeviceListError extends Error {
  constructor(public readonly reason: string) {
    super(`canonical device list rejected: ${reason}`);
    this.name = 'CanonicalDeviceListError';
  }
}

function validString(value: string, maxLength: number): boolean {
  if (value.length === 0 || value.length > maxLength) return false;
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i);
    // Control characters rejected (spec §3), including DEL.
    if (unit < 0x20 || unit === 0x7f) return false;
  }
  return true;
}

/** Canonical escaping: exactly `"` and `\`; everything else raw UTF-8. */
function escapeString(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function writeEntry(d: DeviceListEntry): string {
  let out = `{"addedAt":${d.addedAt},"deviceId":${d.deviceId}`;
  if (d.name !== undefined) out += `,"name":"${escapeString(d.name)}"`;
  out += `,"platform":"${escapeString(d.platform)}"`;
  if (d.revokedAt !== undefined) out += `,"revokedAt":${d.revokedAt}`;
  return out + '}';
}

function isCanonicalInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value);
}

/**
 * Serializes [list] to its canonical bytes, enforcing every §3 constraint at
 * write time. Throws {@link CanonicalDeviceListError} on any violation.
 */
export function encodeCanonicalDeviceList(list: ParsedDeviceList): Buffer {
  if (!isCanonicalInt(list.userId) || list.userId < 1) {
    throw new CanonicalDeviceListError('userId must be a positive int');
  }
  if (!isCanonicalInt(list.version) || list.version < 1) {
    throw new CanonicalDeviceListError('version must be >= 1');
  }
  if (
    !Array.isArray(list.devices) ||
    list.devices.length === 0 ||
    list.devices.length > DEVICE_LIST_MAX_ENTRIES
  ) {
    throw new CanonicalDeviceListError(
      `devices must hold 1..${DEVICE_LIST_MAX_ENTRIES} entries`,
    );
  }
  let previousDeviceId = 0;
  for (const d of list.devices) {
    // Ascending unique deviceIds: the ONE ordering a verifier can check, so
    // two encodings of the same set cannot both be canonical.
    if (!isCanonicalInt(d.deviceId) || d.deviceId <= previousDeviceId) {
      throw new CanonicalDeviceListError(
        'devices must be sorted by strictly ascending positive id',
      );
    }
    previousDeviceId = d.deviceId;
    if (
      !isCanonicalInt(d.addedAt) ||
      d.addedAt < 0 ||
      (d.revokedAt !== undefined &&
        (!isCanonicalInt(d.revokedAt) || d.revokedAt < 0))
    ) {
      throw new CanonicalDeviceListError(
        'timestamps must be non-negative integers',
      );
    }
    if (
      typeof d.platform !== 'string' ||
      !validString(d.platform, DEVICE_PLATFORM_MAX_LENGTH)
    ) {
      throw new CanonicalDeviceListError(
        `platform must be 1..${DEVICE_PLATFORM_MAX_LENGTH} chars without control characters`,
      );
    }
    if (d.name !== undefined) {
      if (
        typeof d.name !== 'string' ||
        !validString(d.name, DEVICE_NAME_MAX_LENGTH)
      ) {
        throw new CanonicalDeviceListError(
          `name must be 1..${DEVICE_NAME_MAX_LENGTH} chars without control characters`,
        );
      }
      // Server-side only (see header): reject a non-NFC name at the gate.
      if (d.name !== d.name.normalize('NFC')) {
        throw new CanonicalDeviceListError('name must be NFC-normalized');
      }
    }
  }

  const body = list.devices.map(writeEntry).join(',');
  return Buffer.from(
    `{"userId":${list.userId},"version":${list.version},"devices":[${body}]}`, // log-guard: key
    'utf8',
  );
}

function requireInt(value: unknown, field: string): number {
  if (!isCanonicalInt(value)) {
    throw new CanonicalDeviceListError(`${field} not an int`);
  }
  return value;
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string') {
    throw new CanonicalDeviceListError(`${field} not a string`);
  }
  return value;
}

const ENTRY_KEYS: Record<string, true> = {
  addedAt: true,
  deviceId: true,
  name: true,
  platform: true,
  revokedAt: true,
};

/**
 * Strictly parses canonical device-list bytes (falsification 23).
 *
 * Signatures are ALWAYS verified over the received bytes verbatim, never over
 * anything this returns — the re-encode below exists only to prove the input
 * is the one canonical form.
 */
export function parseCanonicalDeviceList(bytes: Buffer): ParsedDeviceList {
  // Strict UTF-8: a re-encode differing from the input means invalid or
  // non-shortest-form sequences that toString() silently repaired.
  const text = bytes.toString('utf8');
  if (!Buffer.from(text, 'utf8').equals(bytes)) {
    throw new CanonicalDeviceListError('not valid UTF-8');
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(text);
  } catch {
    throw new CanonicalDeviceListError('not valid JSON');
  }
  if (
    typeof decoded !== 'object' ||
    decoded === null ||
    Array.isArray(decoded)
  ) {
    throw new CanonicalDeviceListError('top level not an object');
  }
  const top = decoded as Record<string, unknown>;
  const topKeys = Object.keys(top);
  if (
    topKeys.length !== 3 ||
    !('userId' in top) ||
    !('version' in top) ||
    !('devices' in top)
  ) {
    throw new CanonicalDeviceListError(
      'top-level keys must be exactly userId, version, devices',
    );
  }
  const userId = requireInt(top.userId, 'userId');
  const version = requireInt(top.version, 'version');
  if (!Array.isArray(top.devices)) {
    throw new CanonicalDeviceListError('devices not an array');
  }

  const devices: DeviceListEntry[] = [];
  for (const rawEntry of top.devices) {
    if (
      typeof rawEntry !== 'object' ||
      rawEntry === null ||
      Array.isArray(rawEntry)
    ) {
      throw new CanonicalDeviceListError('device entry not an object');
    }
    const entry = rawEntry as Record<string, unknown>;
    const keys = Object.keys(entry);
    if (
      keys.some((k) => !(k in ENTRY_KEYS)) ||
      !('addedAt' in entry) ||
      !('deviceId' in entry) ||
      !('platform' in entry)
    ) {
      throw new CanonicalDeviceListError('device entry keys invalid');
    }
    devices.push({
      deviceId: requireInt(entry.deviceId, 'deviceId'),
      platform: requireString(entry.platform, 'platform'),
      addedAt: requireInt(entry.addedAt, 'addedAt'),
      ...('name' in entry ? { name: requireString(entry.name, 'name') } : {}),
      ...('revokedAt' in entry
        ? { revokedAt: requireInt(entry.revokedAt, 'revokedAt') }
        : {}),
    });
  }

  const list: ParsedDeviceList = { userId, version, devices };
  // Re-encode runs the writer's own constraint checks too (ranges, ordering,
  // control characters, NFC), then the byte comparison rejects every
  // non-canonical byte form of the same data.
  const reEncoded = encodeCanonicalDeviceList(list);
  if (!reEncoded.equals(bytes)) {
    throw new CanonicalDeviceListError('not canonical bytes');
  }
  return list;
}
