#!/usr/bin/env node
// Falsification harness for verify-apk-signed-matches-unsigned.mjs. Crafts a
// minimal "unsigned APK" (a stored-entry zip) and "signed" variants in a temp
// dir, and asserts the gate PASSES on the honest pair and FAILS on every way a
// signed file can differ from the unsigned one beyond padding + signing block.
// Run: node scripts/verify-apk-signed-matches-unsigned.selftest.mjs

import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const checker = join(
  dirname(fileURLToPath(import.meta.url)),
  'verify-apk-signed-matches-unsigned.mjs',
);

// ---- minimal zip: stored entries, central directory, end record ----
function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const { name, data } of files) {
    const nameBuf = Buffer.from(name, 'utf8');
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    const localFull = Buffer.concat([local, nameBuf, data]);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(Buffer.concat([central, nameBuf]));
    locals.push(localFull);
    offset += localFull.length;
  }
  const cd = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(files.length, 8);
  eocd.writeUInt16LE(files.length, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(offset, 16);
  return { bytes: Buffer.concat([...locals, cd, eocd]), cdOffset: offset, cdSize: cd.length };
}

// ---- APK Signing Block: u64 size | one id-value pair | u64 size | magic ----
function signingBlock(payloadLength) {
  const pair = Buffer.alloc(12 + payloadLength, 0xab);
  pair.writeBigUInt64LE(BigInt(4 + payloadLength), 0);
  pair.writeUInt32LE(0x7109871a, 8); // v2 scheme id
  const size = BigInt(pair.length + 8 + 16);
  const head = Buffer.alloc(8);
  head.writeBigUInt64LE(size);
  return Buffer.concat([head, pair, head, Buffer.from('APK Sig Block 42', 'latin1')]);
}

/** The unsigned zip with `padding` zero bytes and a signing block inserted. */
function sign(unsigned, { padding = 20, block = signingBlock(64) } = {}) {
  const { bytes, cdOffset } = unsigned;
  const tail = Buffer.from(bytes.subarray(cdOffset));
  const inserted = padding + block.length;
  tail.writeUInt32LE(cdOffset + inserted, tail.length - 22 + 16);
  return Buffer.concat([bytes.subarray(0, cdOffset), Buffer.alloc(padding), block, tail]);
}

const flip = (buf, at) => {
  const out = Buffer.from(buf);
  out[at] ^= 1;
  return out;
};

const unsigned = zip([
  { name: 'classes.dex', data: Buffer.alloc(300, 0x11) },
  { name: 'lib/arm64-v8a/libapp.so', data: Buffer.alloc(500, 0x22) },
]);
const good = sign(unsigned);
const blockAt = unsigned.cdOffset + 20;

const badSizes = Buffer.from(good);
badSizes.writeBigUInt64LE(badSizes.readBigUInt64LE(blockAt) + 1n, blockAt);

const zip64 = Buffer.from(unsigned.bytes);
zip64.writeUInt32LE(0xffffffff, zip64.length - 22 + 16);

const cases = [
  // [name, signed bytes, unsigned bytes, expected exit code]
  ['honest pair, 20 bytes of padding', good, unsigned.bytes, 0],
  ['honest pair, no padding', sign(unsigned, { padding: 0 }), unsigned.bytes, 0],
  ['honest pair, 4095 bytes of padding', sign(unsigned, { padding: 4095 }), unsigned.bytes, 0],
  ['a byte of an entry changed', flip(good, 40), unsigned.bytes, 1],
  ['a byte of the central directory changed', flip(good, good.length - 30), unsigned.bytes, 1],
  ['padding is not zero', flip(good, unsigned.cdOffset + 3), unsigned.bytes, 1],
  ['4096 bytes of padding', sign(unsigned, { padding: 4096 }), unsigned.bytes, 1],
  ['signing block size fields disagree', badSizes, unsigned.bytes, 1],
  ['bytes appended after the end record', Buffer.concat([good, Buffer.from('x')]), unsigned.bytes, 1],
  ['unsigned file given as signed', unsigned.bytes, unsigned.bytes, 1],
  ['signed file given as unsigned', good, good, 1],
  ['signed file is not a zip', Buffer.alloc(200, 0x33), unsigned.bytes, 1],
  ['unsigned file is zip64', good, zip64, 1],
];

const dir = mkdtempSync(join(tmpdir(), 'apk-signed-selftest-'));
let failed = 0;
try {
  for (const [name, signedBytes, unsignedBytes, expected] of cases) {
    const signedPath = join(dir, 'signed.apk');
    const unsignedPath = join(dir, 'unsigned.apk');
    writeFileSync(signedPath, signedBytes);
    writeFileSync(unsignedPath, unsignedBytes);
    const { status } = spawnSync(process.execPath, [checker, signedPath, unsignedPath], {
      stdio: 'ignore',
    });
    const ok = status === expected;
    if (!ok) failed++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: exit ${status}, expected ${expected}`);
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}

if (failed > 0) {
  console.error(`\n${failed} self-test case(s) failed.`);
  process.exit(1);
}
console.log('\nverify-apk-signed-matches-unsigned.mjs: self-test passed.');
