#!/usr/bin/env node
// verify-signed-matches-unsigned.mjs — proves that a signed APK is the unsigned
// APK built in CI plus a signature, and nothing else.
//
// An APK signed with scheme v2/v3 only (no v1/JAR signing; Umbra has minSdk 24)
// is the unsigned zip with one "APK Signing Block" inserted just before the zip
// central directory, and the central-directory offset in the end record moved
// accordingly. apksigner also puts up to 4095 zero bytes in front of the block
// so that it starts on a 4096-byte boundary (MEASURED with build-tools 36.0.0:
// 20 bytes). This script takes the padding and the block out of the signed
// file, puts the offset back, and requires the result to be byte-identical to
// the unsigned file (falsified by verify-apk-signed-matches-unsigned.selftest.mjs).
// Anyone can run it on the two published files. It does
// NOT check the signature itself: `apksigner verify --print-certs` does that.
//
// The signer must run `apksigner sign --alignment-preserved true`: without it
// apksigner rewrites the alignment padding of every stored entry, and this
// check fails (MEASURED). scripts/apk/sign-ci-apk.ps1 does.
//
// Fails (exit 1) when: the signed file has no signing block, the unsigned file
// has one, either file is not a plain (non-zip64) zip, the padding is not all
// zero or is 4096 bytes or more, or one byte differs.
//
// Usage: node scripts/verify-apk-signed-matches-unsigned.mjs <signed.apk> <unsigned.apk>

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const EOCD_SIG = 0x06054b50;
const EOCD_MIN = 22;
const MAGIC = Buffer.from('APK Sig Block 42', 'latin1');

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

/** Offsets of the end-of-central-directory record and the central directory. */
function zipLayout(buf, label) {
  // The record ends the file, followed only by its own comment (max 65535).
  const lowest = Math.max(0, buf.length - EOCD_MIN - 0xffff);
  for (let at = buf.length - EOCD_MIN; at >= lowest; at--) {
    if (buf.readUInt32LE(at) !== EOCD_SIG) continue;
    if (at + EOCD_MIN + buf.readUInt16LE(at + 20) !== buf.length) continue;
    const cdSize = buf.readUInt32LE(at + 12);
    const cdOffset = buf.readUInt32LE(at + 16);
    if (cdOffset === 0xffffffff) fail(`${label}: zip64 archives are not supported`);
    if (cdOffset + cdSize !== at) {
      fail(`${label}: central directory does not end at the end record`);
    }
    return { eocd: at, cdOffset };
  }
  return fail(`${label}: no zip end-of-central-directory record`);
}

/** Start of the APK Signing Block that ends at `cdOffset`, or null. */
function signingBlockStart(buf, cdOffset, label) {
  if (cdOffset < 32) return null;
  if (!buf.subarray(cdOffset - 16, cdOffset).equals(MAGIC)) return null;
  // Layout: u64 size | id-value pairs | u64 size | magic. `size` counts
  // everything after the first size field.
  const size = buf.readBigUInt64LE(cdOffset - 24);
  const start = BigInt(cdOffset) - size - 8n;
  if (start < 0n) fail(`${label}: signing block size runs past the file start`);
  if (buf.readBigUInt64LE(Number(start)) !== size) {
    fail(`${label}: signing block size fields disagree`);
  }
  return Number(start);
}

const [signedPath, unsignedPath] = process.argv.slice(2);
if (!signedPath || !unsignedPath) {
  console.error(
    'Usage: node scripts/verify-apk-signed-matches-unsigned.mjs <signed.apk> <unsigned.apk>',
  );
  process.exit(2);
}

const signed = readFileSync(signedPath);
const unsigned = readFileSync(unsignedPath);

const u = zipLayout(unsigned, 'unsigned');
if (signingBlockStart(unsigned, u.cdOffset, 'unsigned') !== null) {
  fail('the file given as unsigned carries an APK Signing Block');
}

const s = zipLayout(signed, 'signed');
const blockStart = signingBlockStart(signed, s.cdOffset, 'signed');
if (blockStart === null) {
  fail('the signed file has no APK Signing Block (unsigned, or v1/JAR-signed only)');
}

// Everything before the unsigned file's central directory is zip entries; the
// signed file must carry the same bytes there, then only zero padding.
const padding = signed.subarray(u.cdOffset, blockStart);
if (blockStart < u.cdOffset || padding.length >= 4096 || padding.some((b) => b !== 0)) {
  fail('the bytes between the zip entries and the signing block are not plain padding');
}
const inserted = s.cdOffset - u.cdOffset;
const stripped = Buffer.concat([
  signed.subarray(0, u.cdOffset),
  signed.subarray(s.cdOffset),
]);
stripped.writeUInt32LE(u.cdOffset, s.eocd - inserted + 16);

const unsignedSha = sha256(unsigned);
const strippedSha = sha256(stripped);
console.log(`signed            ${sha256(signed)}  (${signed.length} bytes)`);
console.log(`unsigned          ${unsignedSha}  (${unsigned.length} bytes)`);
console.log(`signed, sig out   ${strippedSha}  (${stripped.length} bytes)`);
console.log(`signing block     ${s.cdOffset - blockStart} bytes, after ${padding.length} bytes of zero padding`);
if (strippedSha !== unsignedSha || !stripped.equals(unsigned)) {
  fail('the signed APK is NOT the unsigned APK plus a signature');
}
console.log('OK: the signed APK is the unsigned APK plus a signature, byte for byte.');
