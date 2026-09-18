# staging.ps1 -- local production dress-rehearsal stack (run on the dev PC, never the VM).
#
# Boots the REAL prod compose (built image, NODE_ENV=production, TypeORM sync OFF,
# restricted CORS) isolated as project `fireplace-staging`: backend :3100, db :5533,
# own volumes. See docker-compose.staging.yml for the isolation contract.
#
# Commands:
#   .\staging.ps1 up               build + start; warns if the schema is empty
#   .\staging.ps1 seed-schema      one-shot dev-mode boot (TypeORM sync creates schema
#                                  from entities), then flips back to production
#   .\staging.ps1 restore <dump>   pg_restore a backup (.dump or .dump.gpg) into staging;
#                                  gpg passphrase is prompted, never stored
#   .\staging.ps1 sql <file.sql>   run a migration file against staging (ON_ERROR_STOP)
#   .\staging.ps1 harness          run the E2E wire harness against staging (:3100)
#   .\staging.ps1 status           compose ps + /health + /version
#   .\staging.ps1 down             stop containers (volumes kept)
#   .\staging.ps1 destroy          stop + WIPE volumes (asks for confirmation)
#
# Migration rehearsal workflow:
#   .\staging.ps1 up ; .\staging.ps1 restore ~\fireplace-backups\chatdb-<ts>.dump.gpg
#   .\staging.ps1 sql migration.sql ; .\staging.ps1 harness
#   -> green? run the same SQL on the VPS, then ./deploy-backend.sh there.

param(
    [Parameter(Position = 0)] [string]$Command = 'help',
    [Parameter(Position = 1)] [string]$Target
)

$ErrorActionPreference = 'Stop'
$RepoDir    = $PSScriptRoot
$Project    = 'fireplace-staging'
$EnvFile    = Join-Path $RepoDir '.env.staging'
$BackendUrl = 'http://localhost:3100'
$BackendCtr = 'fireplace-staging-backend-1'
$DbCtr      = 'fireplace-staging-db-1'

# The overlay's `!override` ports tag needs docker compose >= 2.24. An older
# compose fails to parse it (safe abort), but never risk the default list-MERGE
# semantics, which would append staging ports onto prod's and collide with the
# dev stack (:3000/:5433).
$composeVer = (docker compose version --short) 2>$null
if ($composeVer -and (($composeVer -replace '^v', '') -match '^(\d+)\.(\d+)')) {
    if ([version]"$($Matches[1]).$($Matches[2])" -lt [version]'2.24') {
        throw "docker compose $composeVer is too old: the staging overlay needs >= 2.24 (!override)"
    }
}

function Invoke-Compose {
    docker compose -p $Project --env-file $EnvFile `
        -f (Join-Path $RepoDir 'docker-compose.prod.yml') `
        -f (Join-Path $RepoDir 'docker-compose.staging.yml') @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($args -join ' ') failed ($LASTEXITCODE)" }
}

function Initialize-EnvFile {
    if (Test-Path $EnvFile) { return }
    Write-Host '==> creating .env.staging from template (random dummy JWT_SECRET)'
    $secret = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    (Get-Content (Join-Path $RepoDir '.env.staging.example')) `
        -replace '^JWT_SECRET=.*$', "JWT_SECRET=staging-$secret" |
        Set-Content $EnvFile -Encoding ascii
}

function Set-VersionEnv {
    Push-Location $RepoDir
    try {
        $env:GIT_COMMIT  = (git rev-parse --short HEAD 2>$null); if (-not $env:GIT_COMMIT) { $env:GIT_COMMIT = 'unknown' }
        $env:BUILD_TIME  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $version = (Select-String -Path 'frontend/pubspec.yaml' -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
        $env:APP_VERSION = ($version -split '\+')[0]
    } finally { Pop-Location }
}

function Wait-BackendHealthy {
    Write-Host '==> waiting for backend health'
    for ($i = 1; $i -le 24; $i++) {
        Start-Sleep -Seconds 5
        $status = docker inspect -f '{{.State.Health.Status}}' $BackendCtr 2>$null
        Write-Host "   [$($i * 5)s] health=$status"
        if ($status -eq 'healthy') { return }
    }
    throw "backend not healthy -- check: docker logs $BackendCtr --tail 80"
}

function Get-PublicTableCount {
    $count = docker exec $DbCtr psql -U postgres -d chatdb -tAc `
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>$null
    if ($LASTEXITCODE -ne 0) { return -1 }
    return [int]$count.Trim()
}

function Show-Status {
    Invoke-Compose ps
    try {
        Write-Host "==> $BackendUrl/health";  (Invoke-RestMethod "$BackendUrl/health")  | ConvertTo-Json -Compress | Write-Host
        Write-Host "==> $BackendUrl/version"; (Invoke-RestMethod "$BackendUrl/version") | ConvertTo-Json -Compress | Write-Host
    } catch { Write-Warning "backend not reachable at $BackendUrl : $_" }
}

function Set-MediaVolumeOwnership {
    # Backend runs as non-root 'node' (uid 1000); volumes created by older
    # root images stay root-owned. Idempotent, mirrors deploy-backend.sh.
    docker run --rm -v "${Project}_media_storage:/media" alpine:3 chown -R 1000:1000 /media | Out-Null
}

function Start-Stack {
    Initialize-EnvFile
    Set-VersionEnv
    Remove-Item Env:\STAGING_NODE_ENV -ErrorAction SilentlyContinue  # default: production
    Write-Host "==> staging up  version=$env:APP_VERSION commit=$env:GIT_COMMIT (NODE_ENV=production)"
    Invoke-Compose build backend
    Set-MediaVolumeOwnership
    Invoke-Compose up -d
    Wait-BackendHealthy
    Show-Status
    $tables = Get-PublicTableCount
    if ($tables -eq 0) {
        Write-Warning 'schema is EMPTY (prod mode never auto-creates it) -- run: .\staging.ps1 seed-schema  or  .\staging.ps1 restore <dump>'
    } else {
        Write-Host "==> public tables: $tables"
    }
}

switch ($Command) {
    'up' { Start-Stack }

    'seed-schema' {
        Initialize-EnvFile
        Set-VersionEnv
        Write-Host '==> one-shot dev-mode boot (TypeORM synchronize creates schema from entities)'
        $env:STAGING_NODE_ENV = 'development'
        try {
            Invoke-Compose build backend
            Set-MediaVolumeOwnership
            Invoke-Compose up -d
            Wait-BackendHealthy
        } finally {
            Remove-Item Env:\STAGING_NODE_ENV -ErrorAction SilentlyContinue
        }
        Write-Host '==> schema created; flipping back to NODE_ENV=production'
        Invoke-Compose up -d   # env change recreates the backend container
        Wait-BackendHealthy
        Write-Host "==> public tables: $(Get-PublicTableCount)"
        Show-Status
    }

    'restore' {
        if (-not $Target) { throw 'usage: .\staging.ps1 restore <chatdb-*.dump[.gpg]>' }
        $dump = Resolve-Path $Target
        Initialize-EnvFile
        Set-VersionEnv
        # Defensive: a leaked STAGING_NODE_ENV=development (e.g. hard-interrupted
        # seed-schema in this same shell) would boot the restored PROD DATA in dev
        # mode with TypeORM auto-DDL -- the exact thing this rehearsal must not do.
        Remove-Item Env:\STAGING_NODE_ENV -ErrorAction SilentlyContinue
        Invoke-Compose up -d db
        Start-Sleep -Seconds 3

        $plainDump = $dump.Path
        $tempDir = $null
        if ($dump.Path -match '\.gpg$') {
            Write-Host '==> decrypting dump in a throwaway container (passphrase prompted, never stored)'
            $tempDir = Join-Path $env:TEMP "fireplace-staging-restore-$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir | Out-Null
            $pass = Read-Host 'Backup passphrase' -AsSecureString
            $plain = [System.Net.NetworkCredential]::new('', $pass).Password
            # PS 5.1 pipes to native processes via $OutputEncoding (default ASCII);
            # force UTF-8 so a non-ASCII passphrase survives the stdin pipe to gpg.
            $prevEnc = $OutputEncoding
            $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $inDir  = Split-Path $dump.Path
            $inFile = Split-Path $dump.Path -Leaf
            # Passphrase over stdin (fd 0); ciphertext + output via mounts -- nothing
            # binary crosses a PowerShell pipe (PS pipes corrupt binary streams).
            $plain | docker run --rm -i `
                -v "${inDir}:/in:ro" -v "${tempDir}:/out" `
                alpine:3.20 sh -c "apk add -q gnupg && gpg --batch --pinentry-mode loopback --passphrase-fd 0 --output /out/staging.dump --decrypt /in/$inFile"
            $plain = $null
            $OutputEncoding = $prevEnc
            if ($LASTEXITCODE -ne 0) { throw 'gpg decryption failed (wrong passphrase?)' }
            $plainDump = Join-Path $tempDir 'staging.dump'
        }

        try {
            Write-Host '==> restoring into staging chatdb (backend stopped during restore)'
            Invoke-Compose stop backend
            if (-not (Test-Path $plainDump -PathType Leaf)) { throw "not a file: $plainDump" }
            docker exec $DbCtr rm -rf /tmp/restore.dump | Out-Null
            docker cp $plainDump "${DbCtr}:/tmp/restore.dump"
            if ($LASTEXITCODE -ne 0) { throw 'docker cp failed' }
            # Mirror restore-db.sh exactly (--clean --if-exists --single-transaction,
            # no --no-owner) so the rehearsal matches the real prod restore path.
            docker exec $DbCtr pg_restore -U postgres -d chatdb --clean --if-exists --single-transaction /tmp/restore.dump
            if ($LASTEXITCODE -ne 0) { throw 'pg_restore failed (transaction rolled back)' }
        } finally {
            if ($tempDir) { Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue }
            # Plaintext dump must not linger in the container even when pg_restore threw.
            docker exec $DbCtr rm -rf /tmp/restore.dump 2>$null | Out-Null
        }
        Invoke-Compose up -d
        Wait-BackendHealthy
        Write-Host "==> restore done; public tables: $(Get-PublicTableCount)"
    }

    'sql' {
        if (-not $Target) { throw 'usage: .\staging.ps1 sql <file.sql>' }
        $file = Resolve-Path $Target
        if (-not (Test-Path $file.Path -PathType Leaf)) { throw "not a file: $($file.Path)" }
        # Pre-clean: if the target exists as a DIRECTORY (e.g. from an aborted
        # run), docker cp would place the file INSIDE it instead of replacing.
        docker exec $DbCtr rm -rf /tmp/staging.sql | Out-Null
        docker cp $file.Path "${DbCtr}:/tmp/staging.sql"
        if ($LASTEXITCODE -ne 0) { throw 'docker cp failed (is staging up?)' }
        # lock_timeout: DDL needing ACCESS EXCLUSIVE fails fast instead of hanging
        # behind an in-flight transaction (same habit applies on the VPS: run prod
        # SQL with PGOPTIONS='-c lock_timeout=10s').
        docker exec -e PGOPTIONS='-c lock_timeout=10s' $DbCtr psql -U postgres -d chatdb -v ON_ERROR_STOP=1 -f /tmp/staging.sql
        $rc = $LASTEXITCODE
        docker exec $DbCtr rm -rf /tmp/staging.sql | Out-Null
        if ($rc -ne 0) { throw "psql failed ($rc)" }
        Write-Host '==> SQL applied to staging'
    }

    'harness' {
        Write-Host '==> running E2E wire harness against staging (prod-mode backend)'
        $env:E2E_BASE_URL = $BackendUrl
        # The opt-in SQL channel (`e2eSql`, frontend/test_e2e/support/e2e_test_client.dart)
        # defaults to `fireplace-db-1` -- the DEV stack's container, which on this PC is a
        # different session's live database. Without this the harness reads and WRITES
        # (`DELETE FROM identity_reset_requests`, `UPDATE recovery_keys`) against that DB
        # instead of staging: the staging rows never move, so `registration_lock_test`
        # fails with `existing`/`cooldown` mismatches that look like product bugs.
        $env:E2E_DB_CONTAINER = $DbCtr
        try {
            Push-Location (Join-Path $RepoDir 'frontend')
            flutter test test_e2e
            if ($LASTEXITCODE -ne 0) { throw 'harness failed against staging' }
        } finally {
            Pop-Location
            Remove-Item Env:\E2E_BASE_URL -ErrorAction SilentlyContinue
            Remove-Item Env:\E2E_DB_CONTAINER -ErrorAction SilentlyContinue
        }
    }

    'status'  { Show-Status }
    'down'    { Invoke-Compose down }

    'destroy' {
        $answer = Read-Host "Type YES to stop staging and WIPE its volumes ($Project)"
        if ($answer -cne 'YES') { Write-Host 'aborted'; exit 1 }
        Invoke-Compose down -v
        Write-Host '==> staging destroyed (containers + volumes)'
    }

    default {
        Write-Host 'usage: .\staging.ps1 up | seed-schema | restore <dump> | sql <file> | harness | status | down | destroy'
        Write-Host 'see header of this file for the migration-rehearsal workflow'
    }
}
