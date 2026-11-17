<#
.SYNOPSIS
  Build the SIGNED release APK for sideload distribution (self-hosted /apk/),
  or with -Bundle the SIGNED release App Bundle (.aab) for Google Play.

.WHY
  Android release has hard gates a plain `flutter build apk` doesn't enforce:
  - release signing must exist (Gradle now throws without key.properties);
  - the webcrypto 16KB page-size patch lives in the PUB CACHE and silently
    disappears on `pub cache repair` / SDK upgrade — so the built APK is
    verified structurally (ELF PT_LOAD alignment) after every build;
  - a debug-signed "release" must never ship;
  - Play needs a monotonically increasing versionCode, which pubspec's semver
    string deliberately does not carry (root CLAUDE.md §5).

.USAGE
  One-time setup (keystore + key.properties): docs/runbooks/android-release.md
  Build:            .\build-android.ps1
  Skip clean build: .\build-android.ps1 -SkipClean
  Play bundle:      .\build-android.ps1 -Bundle   (same defines + versionCode;
                    gates run on the .aab: jarsigner signer check + 16KB ELF)

.VERSIONCODE
  Derived from pubspec semver: major*1_000_000 + minor*10_000 + patch.
  0.0.136 -> 136, 0.1.0 -> 10000. Monotonic as long as semver only grows.
  Passed via --build-number; pubspec.yaml NEVER gets a +N suffix.
#>
[CmdletBinding()]
param(
  [string]$BaseUrl     = "https://fireplace.ignorelist.com",
  # Private Giphy key — set in gitignored deploy-web.config.ps1 or the env var.
  [string]$GiphyApiKey = "$env:GIPHY_API_KEY",
  [switch]$SkipClean,
  # Build the Play App Bundle instead of the sideload APK.
  [switch]$Bundle
)

# NOTE: deliberately NOT $ErrorActionPreference='Stop' — native tools write
# progress to stderr, which Stop would treat as fatal. We check $LASTEXITCODE.

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repo

# Reuse the web deploy's gitignored config (GiphyApiKey lives there too).
$cfg = Join-Path $repo "deploy-web.config.ps1"
if ((Test-Path $cfg) -and -not $GiphyApiKey) { . $cfg }

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ---------- preconditions ----------
Step "Preconditions"
if (-not (Test-Path "frontend/android/key.properties")) {
  Fail "frontend/android/key.properties missing - no release signing. Follow docs/runbooks/android-release.md (one-time keystore setup) first."
}
# apksigner, NOT keytool: with minSdk 24 AGP disables v1/JAR signing, so
# `keytool -printcert -jarfile` reports "not signed" on every good v2/v3-only
# APK. apksigner verifies v1/v2/v3 and exits non-zero on unsigned.
$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $sdkRoot) {
  $cand = Join-Path $env:LOCALAPPDATA "Android\Sdk"
  if (Test-Path $cand) { $sdkRoot = $cand }
}
$apksigner = $null
if ($sdkRoot -and -not $Bundle) {
  $apksigner = Get-ChildItem "$sdkRoot\build-tools\*\apksigner.bat" -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Directory.Name -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } |
    Select-Object -Last 1
}
if (-not $Bundle -and -not $apksigner) {
  Fail "apksigner.bat not found under an Android SDK build-tools dir (ANDROID_HOME/ANDROID_SDK_ROOT/%LOCALAPPDATA%\Android\Sdk) - cannot verify the APK signer."
}
# A .aab carries only a JAR (v1) signature, which apksigner does not verify:
# jarsigner does. Prefer JAVA_HOME, then Android Studio's bundled JBR.
$jarsigner = $null
if ($Bundle) {
  $jsCands = @()
  if ($env:JAVA_HOME) { $jsCands += (Join-Path $env:JAVA_HOME "bin\jarsigner.exe") }
  $jsCands += "C:\Program Files\Android\Android Studio\jbr\bin\jarsigner.exe"
  $jarsigner = $jsCands | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $jarsigner) {
    Fail "jarsigner.exe not found (JAVA_HOME\bin or Android Studio jbr\bin) - cannot verify the bundle signer."
  }
  Write-Host "jarsigner: $jarsigner"
} else {
  Write-Host "apksigner: $($apksigner.FullName)"
}

# ---------- repo state ----------
Step "Repo state"
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$commit = (git rev-parse --short HEAD).Trim()
$verLine = (Select-String -Path frontend/pubspec.yaml -Pattern '^version:').Line
$ver = ($verLine -replace 'version:\s*', '').Trim()
if ($ver -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
  Fail "pubspec version '$ver' is not plain MAJOR.MINOR.PATCH (a +N suffix is banned by root CLAUDE.md par.5)."
}
$buildNumber = [int]$Matches[1] * 1000000 + [int]$Matches[2] * 10000 + [int]$Matches[3]
Write-Host "branch=$branch  commit=$commit  version=$ver  versionCode=$buildNumber"
git fetch origin --quiet 2>$null
$behind = (git rev-list "HEAD..origin/$branch" --count 2>$null)
if ($behind -and ([int]$behind) -gt 0) {
  Write-Warning "Local $branch is $behind commit(s) behind origin/$branch - run 'git pull' first to build the latest."
}

# ---------- deps + 16KB patch ----------
Step "flutter pub get + webcrypto 16KB patch"
Push-Location frontend
flutter pub get
if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "flutter pub get failed" }
# Best-effort APPLICATION of the pub-cache patch. The hard GATE is the
# post-build ELF check below - it catches every way this can silently drop.
& .\patch_webcrypto_16k.ps1
if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "patch_webcrypto_16k.ps1 failed" }
Pop-Location

# ---------- build ----------
Step "Build release $(if ($Bundle) { 'App Bundle' } else { 'APK' })  [several minutes]"
$buildTime = [DateTime]::UtcNow.ToString("s") + "Z"
$defines = @(
  "--dart-define=BASE_URL=$BaseUrl",
  "--dart-define=GIT_COMMIT=$commit",
  "--dart-define=BUILD_TIME=$buildTime",
  "--dart-define=GIPHY_API_KEY=$GiphyApiKey"
)
if (-not $GiphyApiKey) {
  Write-Warning "GIPHY_API_KEY not set - GIF search will use the embedded fallback key."
}
Push-Location frontend
if (-not $SkipClean) {
  # Windows: a live Gradle daemon holds file handles inside frontend\build, which
  # makes `flutter clean` HALF-delete the tree (it warns and continues) and the
  # subsequent build then dies on locked leftovers. Stop daemons first.
  & .\android\gradlew.bat --stop 2>$null | Out-Null
  flutter clean
  if (Test-Path "build") {
    Write-Warning "frontend\build survived flutter clean (file locks?) - close IDEs/emulators if the build fails on locked files."
  }
}
if ($Bundle) {
  flutter build appbundle --release --build-number=$buildNumber @defines
} else {
  flutter build apk --release --build-number=$buildNumber @defines
}
$buildExit = $LASTEXITCODE
Pop-Location
# $apk names the artifact either way: both gates below read it as a zip.
$apk = if ($Bundle) { "frontend/build/app/outputs/bundle/release/app-release.aab" }
       else { "frontend/build/app/outputs/flutter-apk/app-release.apk" }
if ($buildExit -ne 0 -or -not (Test-Path $apk)) {
  Fail "Build failed (flutter exit=$buildExit) or artifact missing ($apk)."
}

# ---------- gate 1: real release signature, never the debug cert ----------
Step "Verify signer"
if ($Bundle) {
  # NOT -strict: every self-signed cert (our release key included) fails
  # -strict's PKIX chain check (exit 4), so -strict can never pass. Instead:
  # exit 0 + 'jar verified.' + no unsigned entries. MEASURED 2026-11-17.
  $certOut = & $jarsigner -verify -verbose -certs $apk 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $certOut -notmatch 'jar verified\.' -or $certOut -match 'unsigned entries') {
    Fail "jarsigner rejected the bundle signature:`n$($certOut -split "`n" | Select-Object -Last 15 | Out-String)"
  }
  if ($certOut -match 'CN=Android Debug') {
    Fail "Bundle is DEBUG-SIGNED. Play would reject it as the upload key - investigate before uploading."
  }
  $signerLine = ($certOut -split "`n" | Select-String -Pattern 'X\.509, ' | Select-Object -First 1)
  Write-Host "Signer OK: $signerLine"
} else {
  $certOut = & $apksigner.FullName verify --print-certs $apk 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { Fail "apksigner rejected the APK signature:`n$certOut" }
  if ($certOut -match 'CN=Android Debug') {
    Fail "APK is DEBUG-SIGNED. The Gradle gate should have caught this - investigate before shipping."
  }
  $signerLine = ($certOut -split "`n" | Select-String -Pattern 'certificate DN' | Select-Object -First 1)
  Write-Host "Signer OK: $signerLine"
}

# ---------- gate 2: 16KB page-size compliance of every 64-bit .so ----------
Step "Verify 16KB ELF alignment"
node scripts/verify-apk-16k.mjs $apk
if ($LASTEXITCODE -ne 0) { Fail "16KB alignment gate failed - do NOT distribute this APK." }

# ---------- summary ----------
Step "Done"
$size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
$sha = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
Write-Host "Artifact:    $apk  (${size} MB)" -ForegroundColor Green
Write-Host "version:     $ver ($commit)  versionCode=$buildNumber"
Write-Host "SHA256:      $sha"
if ($Bundle) {
  Write-Host "`nNext: upload the .aab in Play Console (owner) - see 'Play App Bundle' in docs/runbooks/android-release.md. The self-hosted APK is a separate .\build-android.ps1 run."
  exit 0
}
Write-Host "`nNext: smoke-test on a real device (checklist items 1-7, incl. the LINK ceremony), then attach to a GitHub Release with the SHA256."
Write-Host "Distribution + user wording (LINK the phone as a 2nd device; enable linking on the web FIRST; never delete accounts or clear site data): docs/runbooks/android-release.md"
