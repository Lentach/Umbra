<#
.SYNOPSIS
  Sign, on the PC, the UNSIGNED release APK that CI built from a tag
  (.github/workflows/release-apk.yml), and prove the signed file is that CI
  file plus a signature and nothing else.

.WHY
  The release keystore never leaves the PC. CI builds the APK from a public tag
  with public logs and publishes it and its SHA-256 in the GitHub release; this
  script adds the signature offline. `scripts/apk/verify-signed-matches-unsigned.mjs`
  then takes the signature back out and requires the bytes to equal the CI file.

.USAGE
  From the repo root:
    .\scripts\apk\sign-ci-apk.ps1 -Tag v0.2.104
    .\scripts\apk\sign-ci-apk.ps1 -Tag v0.2.104 -PublishChecksum
    .\scripts\apk\sign-ci-apk.ps1 -UnsignedApk C:\tmp\umbra-0.2.104-unsigned.apk
  Output: dist\apk\umbra-<version>.apk and umbra-<version>.apk.sha256 (gitignored).
  -PublishChecksum also uploads the .sha256 file to the tag's GitHub release.

.GATES (same as build-android.ps1)
  pinned signer certificate, v2-only signature, 16KB ELF alignment, and the
  signed-equals-unsigned proof.
#>
[CmdletBinding()]
param(
  # Release tag whose assets are downloaded with `gh`. Either this or -UnsignedApk.
  [string]$Tag,
  # A local unsigned APK (a CI artifact downloaded by hand). Skips the download.
  [string]$UnsignedApk,
  [string]$Repo = "Lentach/Umbra",
  [switch]$PublishChecksum,
  # Pinned signer: the record of truth is docs/runbooks/android-release.md.
  [string]$ExpectedSignerSha256 = "8E:9A:6B:F3:7B:58:A8:43:2C:42:D8:9E:31:99:00:7C:4A:A9:07:7E:29:7A:96:6A:2F:2C:A7:58:5C:DF:40:5D"
)

# NOTE: deliberately NOT $ErrorActionPreference='Stop' (see build-android.ps1):
# native tools write progress to stderr. We check $LASTEXITCODE.

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
Set-Location $repoRoot

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }
function NormFp($f) { ($f -replace '[^0-9A-Fa-f]', '').ToLower() }
function Sha256($p) { (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }

if ([bool]$Tag -eq [bool]$UnsignedApk) { Fail "Give exactly one of -Tag or -UnsignedApk." }
if ($PublishChecksum -and -not $Tag) { Fail "-PublishChecksum needs -Tag (the release to upload to)." }
$expectedFp = NormFp $ExpectedSignerSha256
if ($expectedFp.Length -ne 64) { Fail "ExpectedSignerSha256 is not a SHA-256 fingerprint." }

# ---------- preconditions ----------
Step "Preconditions"
$keyProps = "frontend/android/key.properties"
if (-not (Test-Path $keyProps)) {
  Fail "$keyProps missing - no release keystore on this machine. See docs/runbooks/android-release.md."
}
$kp = @{}
foreach ($line in Get-Content $keyProps) {
  if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*)$') { $kp[$Matches[1]] = $Matches[2] }
}
foreach ($k in 'storeFile', 'storePassword', 'keyPassword', 'keyAlias') {
  if (-not $kp[$k]) { Fail "$keyProps has no '$k'." }
}
# Gradle resolves storeFile against the app module (frontend/android/app).
$keystore = [System.IO.Path]::GetFullPath((Join-Path "$repoRoot\frontend\android\app" $kp['storeFile']))
if (-not (Test-Path $keystore)) { Fail "Keystore not found at $keystore." }

$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $sdkRoot) {
  $cand = Join-Path $env:LOCALAPPDATA "Android\Sdk"
  if (Test-Path $cand) { $sdkRoot = $cand }
}
$apksigner = $null
if ($sdkRoot) {
  $apksigner = Get-ChildItem "$sdkRoot\build-tools\*\apksigner.bat" -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Directory.Name -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } |
    Select-Object -Last 1
}
if (-not $apksigner) { Fail "apksigner.bat not found under an Android SDK build-tools dir." }
Write-Host "apksigner: $($apksigner.FullName)"

$outDir = Join-Path $repoRoot "dist\apk"
New-Item -ItemType Directory -Force $outDir | Out-Null

# ---------- the unsigned CI file ----------
if ($Tag) {
  Step "Download the CI build of $Tag"
  $dl = Join-Path $outDir "ci-$Tag"
  if (Test-Path $dl) { Remove-Item -Recurse -Force $dl }
  New-Item -ItemType Directory -Force $dl | Out-Null
  gh release download $Tag --repo $Repo --dir $dl --pattern "umbra-*-unsigned.apk" --pattern "umbra-*-unsigned.apk.sha256"
  if ($LASTEXITCODE -ne 0) { Fail "gh release download failed for $Tag." }
  $found = @(Get-ChildItem $dl -Filter "umbra-*-unsigned.apk")
  if ($found.Count -ne 1) { Fail "Expected one umbra-*-unsigned.apk in release $Tag, found $($found.Count)." }
  $UnsignedApk = $found[0].FullName
  $published = ((Get-Content "$UnsignedApk.sha256" -Raw) -split '\s+')[0].ToLower()
  if ($published -ne (Sha256 $UnsignedApk)) {
    Fail "Downloaded APK does not match the SHA-256 published in the release."
  }
}
if (-not (Test-Path $UnsignedApk)) { Fail "Unsigned APK not found: $UnsignedApk" }
$name = [System.IO.Path]::GetFileName($UnsignedApk)
if ($name -notmatch '^umbra-(\d+\.\d+\.\d+)-unsigned\.apk$') {
  Fail "Unsigned APK must be named umbra-<version>-unsigned.apk (got $name)."
}
$ver = $Matches[1]
if ($Tag -and $Tag -ne "v$ver") { Fail "Tag $Tag does not match the APK version $ver." }
$unsignedSha = Sha256 $UnsignedApk
Write-Host "unsigned: $UnsignedApk"
Write-Host "SHA256:   $unsignedSha"

# The input must really be unsigned: apksigner has to REJECT it.
& $apksigner.FullName verify $UnsignedApk 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Fail "The input APK is already signed - this script signs only the unsigned CI build." }

# ---------- sign ----------
# --alignment-preserved: without it apksigner rewrites the padding of every
# stored entry and gate 3 can no longer match the CI bytes (MEASURED, 36.0.0).
Step "Sign (v2 only, as every shipped Umbra APK)"
$signed = Join-Path $outDir "umbra-$ver.apk"
if (Test-Path $signed) { Remove-Item -Force $signed }
# Passwords go through the environment of this process, never argv.
$env:UMBRA_KS_PASS = $kp['storePassword']
$env:UMBRA_KEY_PASS = $kp['keyPassword']
& $apksigner.FullName sign --ks $keystore --ks-key-alias $kp['keyAlias'] `
  --ks-pass env:UMBRA_KS_PASS --key-pass env:UMBRA_KEY_PASS `
  --v1-signing-enabled false --v2-signing-enabled true `
  --v3-signing-enabled false --v4-signing-enabled false `
  --alignment-preserved true `
  --out $signed $UnsignedApk
$signExit = $LASTEXITCODE
Remove-Item Env:UMBRA_KS_PASS, Env:UMBRA_KEY_PASS -ErrorAction SilentlyContinue
if ($signExit -ne 0 -or -not (Test-Path $signed)) { Fail "apksigner sign failed (exit=$signExit)." }

# ---------- gate 1: pinned signer ----------
Step "Verify signer"
$certOut = & $apksigner.FullName verify --print-certs $signed 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "apksigner rejected the signed APK:`n$certOut" }
if ($certOut -match 'CN=Android Debug') { Fail "APK is DEBUG-SIGNED." }
$fps = @([regex]::Matches($certOut, 'certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)') | ForEach-Object { NormFp $_.Groups[1].Value })
if ($fps.Count -ne 1 -or $fps[0] -ne $expectedFp) {
  Fail "APK signer SHA-256 [$($fps -join ', ')] is not the pinned $ExpectedSignerSha256."
}
Write-Host "Signer OK (pinned SHA-256)."

# ---------- gate 2: 16KB ----------
Step "Verify 16KB ELF alignment"
node scripts/verify-apk-16k.mjs $signed
if ($LASTEXITCODE -ne 0) { Fail "16KB alignment gate failed - do NOT distribute this APK." }

# ---------- gate 3: signed = CI file + signature ----------
Step "Verify the signed APK is the CI build plus a signature"
node scripts/apk/verify-signed-matches-unsigned.mjs $signed $UnsignedApk
if ($LASTEXITCODE -ne 0) { Fail "The signed APK differs from the CI build - do NOT distribute it." }

# ---------- checksum ----------
Step "Done"
$signedSha = Sha256 $signed
$shaFile = "$signed.sha256"
# sha256sum format with LF, so `sha256sum -c` works on the server.
[System.IO.File]::WriteAllText($shaFile, "$signedSha  umbra-$ver.apk`n")
$size = [math]::Round((Get-Item $signed).Length / 1MB, 1)
Write-Host "Artifact:  $signed  (${size} MB)" -ForegroundColor Green
Write-Host "SHA256:    $signedSha"
Write-Host "Checksum:  $shaFile"
if ($PublishChecksum) {
  gh release upload $Tag $shaFile --repo $Repo --clobber
  if ($LASTEXITCODE -ne 0) { Fail "Uploading the checksum to release $Tag failed." }
  Write-Host "Checksum uploaded to release $Tag."
}
Write-Host "`nNext: device smoke, then copy BOTH files to ~/fireplace/apk/ on the server (docs/runbooks/android-release.md)."
