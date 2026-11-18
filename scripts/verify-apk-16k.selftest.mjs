#!/usr/bin/env node
// Falsification harness for verify-apk-16k.mjs. Crafts minimal APKs in a temp
// dir and asserts the gate FAILS on a misaligned lib (the case that matters),
// PASSES on an aligned one, and FAILS on empty/32-bit-only matches.
// Run: node scripts/verify-apk-16k.selftest.mjs

import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const checker = join(dirname(fileURLToPath(import.meta.url)), 'verify-apk-16k.mjs');

// ---- minimal 64-bit little-endian ELF with N PT_LOAD segments ----
function elf64(aligns) {
  const phnum = aligns.length;
  const buf = Buffer.alloc(64 + 56 * phnum);
  buf.writeUInt32BE(0x7f454c46, 0); // magic
  buf[4] = 2; // ELFCLASS64
  buf[5] = 1; // little-endian
  buf[6] = 1; // EV_CURRENT
  buf.writeUInt16LE(3, 16); // e_type ET_DYN
  buf.writeUInt16LE(0xb7, 18); // e_machine aarch64
  buf.writeUInt32LE(1, 20); // e_version
  buf.writeBigUInt64LE(64n, 0x20); // e_phoff
  buf.writeUInt16LE(64, 0x34); // e_ehsize
  buf.writeUInt16LE(56, 0x36); // e_phentsize
  buf.writeUInt16LE(phnum, 0x38); // e_phnum
  aligns.forEach((a, i) => {
    const off = 64 + 56 * i;
    buf.writeUInt32LE(1, off); // p_type PT_LOAD
    buf.writeBigUInt64LE(BigInt(a), off + 0x30); // p_align
  });
  return buf;
}

// ---- minimal zip writer (stored or deflated entries; CRC unchecked by gate) ----
function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const { name, data, deflate } of files) {
    const nameBuf = Buffer.from(name, 'utf8');
    const payload = deflate ? deflateRawSync(data) : data;
    const method = deflate ? 8 : 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(payload.length, 18); // compressed size
    local.writeUInt32LE(data.length, 22); // uncompressed size
    local.writeUInt16LE(nameBuf.length, 26);
    const localFull = Buffer.concat([local, nameBuf, payload]);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(payload.length, 20);
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
  return Buffer.concat([...locals, cd, eocd]);
}

function run(apkPath) {
  try {
    execFileSync(process.execPath, [checker, apkPath], { stdio: 'pipe' });
    return 0;
  } catch (e) {
    return e.status ?? 1;
  }
}

const dir = mkdtempSync(join(tmpdir(), 'apk16k-'));
let failures = 0;
function expect(label, apkBytes, wantExit) {
  const p = join(dir, `${label}.apk`);
  writeFileSync(p, apkBytes);
  const got = run(p);
  const pass = wantExit === 0 ? got === 0 : got !== 0;
  console.log(`${pass ? 'PASS' : 'FAIL'} ${label}: expected exit ${wantExit === 0 ? '0' : 'non-zero'}, got ${got}`);
  if (!pass) failures++;
}

// 1. THE case that matters: misaligned 64-bit lib must FAIL (deflated entry).
expect('misaligned-4k', zip([
  { name: 'lib/arm64-v8a/libwebcrypto.so', data: elf64([16384, 4096]), deflate: true },
]), 1);
// 2. Aligned 64-bit lib must PASS (stored + deflated mix, multiple entries).
expect('aligned-16k', zip([
  { name: 'classes.dex', data: Buffer.from('dex'), deflate: true },
  { name: 'lib/arm64-v8a/libwebcrypto.so', data: elf64([16384, 65536]), deflate: false },
  { name: 'lib/x86_64/libwebcrypto.so', data: elf64([16384]), deflate: true },
]), 0);
// 3. Empty match set must FAIL, never look like success.
expect('no-native-libs', zip([
  { name: 'classes.dex', data: Buffer.from('dex'), deflate: false },
]), 1);
// 4. Only 32-bit ABI must FAIL (Play requires 64-bit; empty 64-bit set = bug magnet).
expect('only-32bit', zip([
  { name: 'lib/armeabi-v7a/libwebcrypto.so', data: elf64([4096]), deflate: false },
]), 1);
// 6. App Bundle layout (base/lib/<abi>/): misaligned must FAIL, aligned PASS.
expect('aab-misaligned-4k', zip([
  { name: 'base/manifest/AndroidManifest.xml', data: Buffer.from('m'), deflate: true },
  { name: 'base/lib/arm64-v8a/libwebcrypto.so', data: elf64([16384, 4096]), deflate: true },
]), 1);
expect('aab-aligned-16k', zip([
  { name: 'base/lib/arm64-v8a/libwebcrypto.so', data: elf64([16384]), deflate: false },
  { name: 'base/lib/x86_64/libwebcrypto.so', data: elf64([65536]), deflate: true },
]), 0);
// 7. A lib nested under some other directory is not a loadable native lib.
expect('aab-libs-outside-lib-dir', zip([
  { name: 'base/assets/lib/arm64-v8a/libwebcrypto.so', data: elf64([16384]), deflate: false },
]), 1);
// 8. Garbage file must FAIL, not crash into a pass.
expect('not-a-zip', Buffer.from('definitely not an apk'), 1);

rmSync(dir, { recursive: true, force: true });
if (failures > 0) {
  console.error(`${failures} self-test case(s) failed`);
  process.exit(1);
}
console.log('verify-apk-16k gate: all falsification cases behave correctly.');
