<#
.SYNOPSIS
  Build the Fireplace Flutter WEB bundle on your PC and publish it to the production VM.

.WHY
  The production VM is small (2 GB RAM) and CANNOT compile the web bundle -
  dart2js runs out of memory and freezes the whole machine. So we build here
  (where there's RAM) and copy the finished static files to the VM, which only
  needs to SERVE them. (Backend deploys stay on the VM - that Docker build is light.)

.USAGE
  1) One-time: copy deploy-web.config.example.ps1 to deploy-web.config.ps1 and set
     your VM target (GcloudUser/Instance/Zone). That file is gitignored.
  2) Deploy:           .\deploy-web.ps1
     Build only:       .\deploy-web.ps1 -SkipPublish -SkipVerify
     Re-publish only:  .\deploy-web.ps1 -SkipBuild
  3) On your phone: fully close + reopen the PWA (NEVER uninstall - that wipes E2E keys).

.SAFETY
  - Only client-visible values go into the bundle (BASE_URL, VAPID public key, git commit, Giphy key).
    The Giphy key is a low-sensitivity CLIENT key kept OUT of the repo (set via config/env), not a server secret.
  - Never run flutter build web on the VM. Never run docker compose down -v on the VM.
  - Publishes via a temp dir + atomic swap, and aborts if the upload looks incomplete.
#>
[CmdletBinding()]
param(
  [string]$BaseUrl        = "https://fireplace.ignorelist.com",
  # VAPID public key - public by design (it is already inside the deployed bundle).
  [string]$VapidPublicKey = "BOyiyoPFLS19q4OUIHdhb97je8EOzxjRIzEafCH1nZqzyKGG6DfytNqFK6u3IaNrgwPSbHuj0Hra1IP-KWX7Prc",
  # Private Giphy key - set in gitignored deploy-web.config.ps1 or the GIPHY_API_KEY env var.
  # NEVER hardcode here (public repo). Empty is allowed (GIF search disabled).
  [string]$GiphyApiKey    = "$env:GIPHY_API_KEY",
  [string]$RemoteDir      = "fireplace", # repo dir on the VM, relative to the SSH user's home
  # Publish target - set these in deploy-web.config.ps1 (gcloud is recommended for a GCP VM):
  [string]$GcloudUser     = "",          # SSH/login user on the VM, e.g. "olek292"  (NOT your local Windows user)
  [string]$GcloudInstance = "",          # GCP instance name, e.g. "fireplace-server"
  [string]$GcloudZone     = "",          # e.g. "europe-central2-a"
  [string]$VmSshTarget    = "",          # fallback (OpenSSH): "user@<external-ip>" with SSH-key access
  [switch]$SkipBuild,
  [switch]$SkipPublish,
  [switch]$SkipVerify
)

# NOTE: deliberately NOT $ErrorActionPreference='Stop' - native tools (flutter/gcloud/ssh)
# write progress to stderr, which Stop would treat as fatal. We check $LASTEXITCODE instead.

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repo

# Load gitignored local config so per-machine values stay out of the public repo.
$cfg = Join-Path $repo "deploy-web.config.ps1"
if (Test-Path $cfg) { . $cfg }

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# Decision 90, E90a: since 0.2.62 a page swaps any push subscription made under
# another VAPID key than its bundle's. A bundle whose key is not the LIVE
# backend's would make every user drop a working subscription for one the
# backend cannot sign for. Publish only a bundle that carries the backend's key
# (a rotation deploys the backend first, then passes -VapidPublicKey here).
function Assert-BundleHasBackendVapidKey([string]$remoteKey) {
  $remoteKey = "$remoteKey".Trim()
  if (-not $remoteKey) {
    throw "Could not read WEB_PUSH_VAPID_PUBLIC_KEY from the live backend - refusing to publish."
  }
  $mainJs = "frontend/build/web/main.dart.js"
  if (-not (Select-String -Path $mainJs -SimpleMatch $remoteKey -Quiet)) {
    throw "VAPID mismatch: $mainJs does not carry the backend's public key ($($remoteKey.PadRight(12).Substring(0, 12))...) - refusing to publish. Deploy the backend's pair first, then build with -VapidPublicKey <its public key>."
  }
  Write-Host "Bundle carries the live backend's VAPID public key." -ForegroundColor Green
}

# ---------- repo state ----------
Step "Repo state"
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$commit = (git rev-parse --short HEAD).Trim()
$verLine = (Select-String -Path frontend/pubspec.yaml -Pattern '^version:').Line
$ver = ($verLine -replace 'version:\s*', '').Trim()
Write-Host "branch=$branch  commit=$commit  version=$ver"
git fetch origin --quiet 2>$null
$behind = (git rev-list "HEAD..origin/$branch" --count 2>$null)
if ($behind -and ([int]$behind) -gt 0) {
  Write-Warning "Local $branch is $behind commit(s) behind origin/$branch - run 'git pull' first to build the latest."
}

# ---------- build ----------
if (-not $SkipBuild) {
  Step "Build web bundle (release)  [~1 min]"
  $buildTime = [DateTime]::UtcNow.ToString("s") + "Z"   # e.g. 2026-06-16T19:58:10Z
  $defines = @(
    "--dart-define=BASE_URL=$BaseUrl",
    "--dart-define=GIT_COMMIT=$commit",
    "--dart-define=BUILD_TIME=$buildTime",
    "--dart-define=WEB_PUSH_VAPID_PUBLIC_KEY=$VapidPublicKey",
    "--dart-define=GIPHY_API_KEY=$GiphyApiKey"
  )
  if (-not $GiphyApiKey) {
    Write-Warning "GIPHY_API_KEY not set - GIF search will be disabled in this build. Set it in deploy-web.config.ps1 or the GIPHY_API_KEY env var."
  }
  Push-Location frontend
  flutter clean
  # --no-wasm-dry-run avoids the memory-heavy wasm probe + its noisy stderr.
  # --no-web-resources-cdn keeps the CanvasKit renderer on OUR origin. Without it
  # flutter_bootstrap.js fetches the WASM renderer from
  # https://www.gstatic.com/flutter-canvaskit/<engineRevision> on every visit —
  # a third-party origin executing script in the origin that holds the Signal
  # keys and both auth tokens, with no SRI and (today) no CSP to constrain it.
  # The same assets are already published under build/web/canvaskit/, so this
  # costs nothing and removes the dependency outright.
  flutter build web --release --no-wasm-dry-run --no-web-resources-cdn @defines
  $buildExit = $LASTEXITCODE
  Pop-Location
  if ($buildExit -ne 0 -or -not (Test-Path frontend/build/web/version.json)) {
    throw "Build failed (flutter exit=$buildExit) or output missing (frontend/build/web/version.json)."
  }
  # Inject the build commit into version.json so the DEPLOY side can prove what
  # is being served (post-deploy-smoke.mjs greps it, and you can curl it).
  # Flutter's generated version.json has no commit field of its own.
  # NOT a client feature: no code in frontend/lib fetches or compares this value.
  # The client shows its COMPILED-IN GIT_COMMIT instead, deliberately — see
  # auth_screen.dart:205-207, "on web that fetches the SERVER's version.json and
  # can lie about the running bundle; the compiled commit cannot." An earlier
  # revision of this comment claimed a client-side stale-bundle nudge exists. It
  # does not; staleness is caught by comparing the footer commit against this.
  $vjPath = "frontend/build/web/version.json"
  $vj = Get-Content $vjPath -Raw | ConvertFrom-Json
  $vj | Add-Member -NotePropertyName gitCommit -NotePropertyValue $commit -Force
  # BOM-free write: PS 5.1's Set-Content -Encoding utf8 prepends a UTF-8 BOM,
  # which breaks JSON.parse / package_info_plus in every web client.
  $vjJson = $vj | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText((Resolve-Path $vjPath), $vjJson, (New-Object System.Text.UTF8Encoding($false)))
  $vjBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $vjPath))
  if ($vjBytes.Length -ge 3 -and $vjBytes[0] -eq 0xEF -and $vjBytes[1] -eq 0xBB -and $vjBytes[2] -eq 0xBF) {
    throw "version.json has a UTF-8 BOM - web clients cannot parse it. Aborting publish."
  }
  Write-Host "Built frontend/build/web  (commit=$commit, version=$ver; gitCommit injected into version.json)" -ForegroundColor Green
}

# ---------- publish (PC -> VM staging -> atomic swap) ----------
if (-not $SkipPublish) {
  $useGcloud = $GcloudUser -and $GcloudInstance -and $GcloudZone -and (Get-Command gcloud -ErrorAction SilentlyContinue)
  if (-not $useGcloud -and -not $VmSshTarget) {
    throw "No publish target. In deploy-web.config.ps1 set GcloudUser+GcloudInstance+GcloudZone (recommended), or VmSshTarget."
  }

  if ($useGcloud) {
    # gcloud on Windows uses PuTTY's pscp, which does NOT expand ~ and will not create
    # the destination dir - so use ABSOLUTE paths and pre-make the staging dir, then scp
    # the 'web' dir INTO it (-> $stg/web) and swap that into frontend-build.
    $tgt   = "$GcloudUser@$GcloudInstance"
    $rHome = "/home/$GcloudUser"
    $stg   = "$rHome/web-staging"
    Step "Publish via gcloud ($tgt / $GcloudZone)"
    Assert-BundleHasBackendVapidKey (gcloud compute ssh $tgt --zone $GcloudZone --command "cd $rHome/$RemoteDir && docker compose -f docker-compose.prod.yml exec -T backend printenv WEB_PUSH_VAPID_PUBLIC_KEY")
    gcloud compute ssh $tgt --zone $GcloudZone --command "rm -rf $stg; mkdir -p $stg"
    gcloud compute scp --recurse frontend/build/web "${tgt}:$stg" --zone $GcloudZone
    if ($LASTEXITCODE -ne 0) { throw "gcloud scp failed (exit=$LASTEXITCODE)." }
    $swap = "test -f $stg/web/version.json && cd $rHome/$RemoteDir && rm -rf frontend-build && mv $stg/web frontend-build && echo PUBLISHED_OK || (echo ABORT-upload-incomplete; exit 1)"
    gcloud compute ssh $tgt --zone $GcloudZone --command $swap
    if ($LASTEXITCODE -ne 0) { throw "Remote swap failed (exit=$LASTEXITCODE). frontend-build left untouched." }
  }
  else {
    # OpenSSH scp expands ~ and creates dirs, so the temp-dir approach works directly.
    Step "Publish via ssh/scp ($VmSshTarget)"
    Assert-BundleHasBackendVapidKey (ssh $VmSshTarget "cd ~/$RemoteDir && docker compose -f docker-compose.prod.yml exec -T backend printenv WEB_PUSH_VAPID_PUBLIC_KEY")
    ssh $VmSshTarget "rm -rf ~/web-staging && mkdir -p ~/web-staging"
    if ($LASTEXITCODE -ne 0) { throw "ssh staging-dir prep failed (exit=$LASTEXITCODE). Check VmSshTarget / SSH access." }
    scp -r frontend/build/web "${VmSshTarget}:web-staging"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit=$LASTEXITCODE). Check VmSshTarget / SSH access." }
    # chmod: Ubuntu 24.04 scp lands dirs 700; nginx (www-data) needs world-readable bundle.
    $swap2 = "test -f ~/web-staging/web/version.json && cd ~/$RemoteDir && rm -rf frontend-build && mv ~/web-staging/web frontend-build && chmod -R a+rX frontend-build && echo PUBLISHED_OK || (echo ABORT-upload-incomplete; exit 1)"
    ssh $VmSshTarget $swap2
    if ($LASTEXITCODE -ne 0) { throw "Remote swap failed (exit=$LASTEXITCODE). frontend-build left untouched." }
  }
  Write-Host "Published to ~/$RemoteDir/frontend-build on the VM." -ForegroundColor Green
}

# ---------- verify ----------
if (-not $SkipVerify) {
  Step "Verify ($BaseUrl)"
  try {
    $vj = Invoke-RestMethod "$BaseUrl/version.json" -TimeoutSec 15
    $bv = Invoke-RestMethod "$BaseUrl/version"      -TimeoutSec 15
    Write-Host ("frontend /version.json -> version={0}" -f $vj.version)
    Write-Host ("backend  /version      -> version={0}  gitCommit={1}" -f $bv.version, $bv.gitCommit)
    if ($vj.version -eq $ver) { Write-Host "OK: served frontend version matches your build ($ver)." -ForegroundColor Green }
    else { Write-Warning "Served frontend version ($($vj.version)) != your build ($ver). Did the publish/swap run?" }
  } catch {
    Write-Warning "Could not reach $BaseUrl : $($_.Exception.Message)"
  }

  # ---- definitive stale-build gate -------------------------------------------------
  # The checks above can BOTH pass while the VM still serves cached JS: version.json is a
  # separate file from the bundle, so a bumped semver proves nothing about the code. The
  # smoke script greps the served main.dart.js for the git short-sha that was compiled
  # into it, which is the only check that actually detects a stale or half-published
  # bundle - including the exit-21 silent-halt trap where the publish step does nothing
  # and says nothing (2026-07-08, 2026-07-15, 2026-07-16).
  #
  # Run from scripts/smoke: that directory has its own package.json and node_modules, and
  # the script's `import("playwright")` only resolves from there.
  $smokeDir = Join-Path $repo "scripts\smoke"
  $smokeJs  = Join-Path $smokeDir "post-deploy-smoke.mjs"

  # Which sha should the SERVED bundle contain?
  #   Normal / -SkipPublish=false : $commit, the sha compiled into the bundle we just built.
  #   -SkipBuild                  : we did NOT build, so current HEAD ($commit) may have moved
  #                                 past the existing bundle. Read the sha out of the built
  #                                 artifact instead, or the gate false-fails on the exact
  #                                 recovery path the failure message recommends.
  $expectCommit = $commit
  if ($SkipBuild) {
    $localVj = Join-Path $repo "frontend\build\web\version.json"
    if (Test-Path $localVj) {
      try {
        $lv = Get-Content $localVj -Raw | ConvertFrom-Json
        if ($lv.gitCommit) {
          $expectCommit = $lv.gitCommit
          if ($expectCommit -ne $commit) {
            Write-Host "-SkipBuild: expecting the PREVIOUSLY BUILT bundle ($expectCommit), not current HEAD ($commit)." -ForegroundColor Yellow
          }
        }
      } catch { Write-Warning "Could not read $localVj - falling back to HEAD ($commit) for the gate." }
    }
  }

  if ($SkipPublish) {
    # Nothing was published, so the server still serves the OLD bundle by definition.
    # Grepping it for the new sha would throw a confusing failure for a run the operator
    # explicitly asked not to publish.
    Write-Host "Skipping the stale-build gate: -SkipPublish was set, so the server was not updated." -ForegroundColor Yellow
  }
  elseif (-not (Test-Path $smokeJs)) {
    throw ("Cannot run the stale-build gate: smoke script missing at $smokeJs.`n" +
           "  Refusing to report a successful deploy that was never verified.`n" +
           "  Deploy anyway (UNVERIFIED) with:  .\deploy-web.ps1 -SkipVerify")
  }
  elseif (-not (Test-Path (Join-Path $smokeDir "node_modules"))) {
    # Deliberately fatal, not a warning. A warning here means a genuinely stale bundle
    # ships behind a yellow line and a green-looking finish, which is precisely the
    # silent failure this gate exists to catch.
    throw ("Cannot run the stale-build gate: scripts/smoke dependencies are not installed.`n" +
           "  One-time fix:  cd scripts\smoke ; npm install ; npx playwright install chromium`n" +
           "  Deploy anyway (UNVERIFIED) with:  .\deploy-web.ps1 -SkipVerify")
  }
  else {
    Step "Post-deploy smoke (stale-build gate)"
    $smokeExit = $null
    Push-Location $smokeDir
    try {
      node "post-deploy-smoke.mjs" --commit $expectCommit --url $BaseUrl
      $smokeExit = $LASTEXITCODE
    } finally { Pop-Location }
    if ($null -eq $smokeExit) {
      throw "Could not run node for the stale-build gate. Is node on PATH? Deploy is UNVERIFIED."
    }
    if ($smokeExit -ne 0) {
      throw ("POST-DEPLOY SMOKE FAILED (exit=$smokeExit). The served bundle does NOT match commit $expectCommit.`n" +
             "  Most likely the publish silently did not run - re-publish WITHOUT rebuilding:  .\deploy-web.ps1 -SkipBuild`n" +
             "  Do NOT tell anyone to reinstall the PWA or clear site data - that destroys their E2E Signal keys.")
    }
    Write-Host "Smoke passed: the served bundle really is $expectCommit." -ForegroundColor Green
  }

  Write-Host "`nLast step: on your phone, fully close + reopen the PWA (do NOT uninstall). Settings footer should read $ver / $commit." -ForegroundColor Yellow
}
