#!/usr/bin/env node
// verify-apk-16k.mjs — HARD GATE: fail if any 64-bit native library inside an
// APK is not 16KB page-size compliant (every PT_LOAD segment must have
// p_align >= 16384). Android 15+ devices with 16KB pages crash on misaligned
// libs and Play rejects them.
//
// WHY THIS EXISTS: the webcrypto linker fix is applied by patching the pub
// cache (frontend/patch_webcrypto_16k.ps1). That patch is silently dropped by
// `flutter pub cache repair`, an SDK upgrade, or any non-Windows build. The
// patch MECHANISM may change freely — this check inspects the built artifact,
// so a broken APK can never ship regardless of how the patch was (not) applied.
//
// Anti-decorative-gate rules (do not weaken):
//   - zero .so entries        => FAIL (a parser bug must not look like success)
//   - zero 64-bit ABI entries => FAIL (Play requires 64-bit anyway)
//   - any parse error         => FAIL
// Falsification proof lives in scripts/verify-apk-16k.selftest.mjs (crafted
// APKs: misaligned => exit 1, aligned => exit 0).
//
// Usage: node scripts/verify-apk-16k.mjs <path-to.apk|path-to.aab>
// An Android App Bundle is also a zip; its base module keeps native libs under
// base/lib/<abi>/ instead of lib/<abi>/. Both layouts are checked.

import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';

const REQUIRED_ALIGN = 16384n;
// The 16KB requirement targets 64-bit ABIs; 32-bit ABIs keep 4KB pages.
const ABIS_64 = ['arm64-v8a', 'x86_64', 'riscv64'];

function fail(msg) {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
}

const apkPath = process.argv[2];
if (!apkPath) fail('usage: node scripts/verify-apk-16k.mjs <path-to.apk>');

let buf;
try {
  buf = readFileSync(apkPath);
} catch (e) {
  fail(`cannot read ${apkPath}: ${e.message}`);
}

// ---- ZIP central directory ----
// Find EOCD (0x06054b50) scanning backwards over the (<=64KB) zip comment.
function findEocd(b) {
  const min = Math.max(0, b.length - 65557);
  for (let i = b.length - 22; i >= min; i--) {
    if (b.readUInt32LE(i) === 0x06054b50) return i;
  }
  return -1;
}

const eocd = findEocd(buf);
if (eocd < 0) fail('not a zip/apk: EOCD record not found');
const cdCount = buf.readUInt16LE(eocd + 10);
const cdOffset = buf.readUInt32LE(eocd + 16);
if (cdOffset === 0xffffffff) fail('zip64 APK not supported by this checker');

const entries = [];
let p = cdOffset;
for (let i = 0; i < cdCount; i++) {
  if (buf.readUInt32LE(p) !== 0x02014b50) fail(`bad central directory entry at ${p}`);
  const method = buf.readUInt16LE(p + 10);
  const compSize = buf.readUInt32LE(p + 20);
  const nameLen = buf.readUInt16LE(p + 28);
  const extraLen = buf.readUInt16LE(p + 30);
  const commentLen = buf.readUInt16LE(p + 32);
  const localOffset = buf.readUInt32LE(p + 42);
  const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
  entries.push({ name, method, compSize, localOffset });
  p += 46 + nameLen + extraLen + commentLen;
}

function entryData(e) {
  // Local header repeats name/extra with its own lengths — data starts after it.
  if (buf.readUInt32LE(e.localOffset) !== 0x04034b50) {
    fail(`${e.name}: bad local file header`);
  }
  const nameLen = buf.readUInt16LE(e.localOffset + 26);
  const extraLen = buf.readUInt16LE(e.localOffset + 28);
  const start = e.localOffset + 30 + nameLen + extraLen;
  const raw = buf.subarray(start, start + e.compSize);
  if (e.method === 0) return raw;
  if (e.method === 8) return inflateRawSync(raw);
  fail(`${e.name}: unsupported compression method ${e.method}`);
}

// ---- ELF program headers ----
function minLoadAlign(name, data) {
  if (data.length < 64 || data.readUInt32BE(0) !== 0x7f454c46) {
    fail(`${name}: not an ELF file`);
  }
  if (data[4] !== 2) fail(`${name}: expected 64-bit ELF in a 64-bit ABI dir`);
  if (data[5] !== 1) fail(`${name}: big-endian ELF unexpected on Android`);
  const phoff = data.readBigUInt64LE(0x20);
  const phentsize = data.readUInt16LE(0x36);
  const phnum = data.readUInt16LE(0x38);
  if (phnum === 0) fail(`${name}: ELF has no program headers`);
  let minAlign = null;
  let loads = 0;
  for (let i = 0; i < phnum; i++) {
    const off = Number(phoff) + i * phentsize;
    if (off + 0x38 > data.length) fail(`${name}: program header ${i} out of bounds`);
    const type = data.readUInt32LE(off);
    if (type !== 1) continue; // PT_LOAD
    loads++;
    const align = data.readBigUInt64LE(off + 0x30);
    if (minAlign === null || align < minAlign) minAlign = align;
  }
  if (loads === 0) fail(`${name}: ELF has no PT_LOAD segments`);
  return minAlign;
}

// APK: lib/<abi>/x.so ; AAB base module: base/lib/<abi>/x.so.
const LIB_PATH = /^(?:base\/)?lib\/([^/]+)\/[^/]+\.so$/;
const soEntries = entries.filter((e) => LIB_PATH.test(e.name));
if (soEntries.length === 0) {
  fail('APK/AAB contains no native libraries under lib/ or base/lib/ — expected webcrypto at least');
}

const relevant = soEntries.filter((e) => ABIS_64.includes(LIB_PATH.exec(e.name)[1]));
if (relevant.length === 0) {
  fail(
    `APK has native libs but NO 64-bit ABI (${soEntries.map((e) => e.name).join(', ')}) — Play requires 64-bit`,
  );
}

let bad = 0;
for (const e of relevant) {
  const minAlign = minLoadAlign(e.name, entryData(e));
  const ok = minAlign >= REQUIRED_ALIGN;
  console.log(`${ok ? 'OK  ' : 'BAD '} ${e.name}  min PT_LOAD align=${minAlign}`);
  if (!ok) bad++;
}

if (bad > 0) {
  fail(
    `${bad} 64-bit librar${bad === 1 ? 'y is' : 'ies are'} not 16KB-aligned. ` +
      'Likely the webcrypto pub-cache patch was dropped — run frontend/patch_webcrypto_16k.ps1 and rebuild.',
  );
}
console.log(`All ${relevant.length} 64-bit native libraries are 16KB page-size compliant.`);
