[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$Changelist,

    [string]$Channel = 'stable',
    [string]$BaseUrl = 'https://nas.tail4f97f9.ts.net',
    [string]$RepoRoot = (Get-Location).Path,
    [string]$DllPath = '',
    [string]$WinmmPath = '',
    [string]$SigningKeyPath = '',

    [switch]$SkipGenerate,
    [switch]$CommitAndPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Invoke-Git {
    param([string[]]$GitArgs)
    & git -C $script:RepoRoot @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') a échoué (code $LASTEXITCODE)."
    }
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Fichier JSON introuvable : $Path"
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        throw "JSON invalide dans '$Path' : $($_.Exception.Message)"
    }
}

function Assert-FileHashAndSize {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [long]$ExpectedSize,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description absent : $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne $ExpectedSize) {
        throw "$Description : taille incorrecte ($($item.Length), attendu $ExpectedSize) : $Path"
    }
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "$Description : SHA-256 incorrect ($actualHash, attendu $ExpectedHash) : $Path"
    }
    Write-Host "  OK  $Description ($($item.Length) octets, SHA256 $actualHash)" -ForegroundColor Green
}

function Get-RepoRelativePath {
    param([string]$Path)
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $rootPrefix = $script:RepoRoot.TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Chemin en dehors du dépôt : $fullPath"
    }
    return $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
}

function Get-SafeArtifactPath {
    param([string]$Directory, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::GetFileName($Name) -ne $Name) {
        throw "Nom d'artefact inattendu ou chemin non autorisé : '$Name'"
    }
    return (Join-Path $Directory $Name)
}

$script:RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$repoTop = (& git -C $script:RepoRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0) { throw "RepoRoot n'est pas un dépôt Git : $script:RepoRoot" }
$script:RepoRoot = (Resolve-Path -LiteralPath $repoTop.Trim()).Path

$platform = 'windows-x86_64'
$updatesRoot = Join-Path $script:RepoRoot 'ParadoxBackend\updates'
$runtimeRoot = Join-Path $updatesRoot 'runtime'
$launcherRoot = Join-Path $script:RepoRoot 'ParadoxLauncher'
$publisher = Join-Path $launcherRoot 'scripts\publish-runtime-update.mjs'

if ([string]::IsNullOrWhiteSpace($DllPath)) {
    $DllPath = Join-Path $script:RepoRoot 'ParadoxRuntime\x64\Release\MysticParadox.dll'
}
if ([string]::IsNullOrWhiteSpace($WinmmPath)) {
    $WinmmPath = Join-Path $script:RepoRoot 'tools\RuntimeLoader\target\release\winmm.dll'
}
if ([string]::IsNullOrWhiteSpace($SigningKeyPath)) {
    $SigningKeyPath = Join-Path $launcherRoot '.secrets\selfhost-runtime-update.private.pem'
}

$requiredFiles = @($DllPath, $WinmmPath)
if (-not $SkipGenerate) {
    $requiredFiles += @($publisher, $SigningKeyPath)
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js est introuvable dans PATH.' }
}
foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Fichier requis introuvable : $required"
    }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git est introuvable dans PATH.' }

$sourceDllItem = Get-Item -LiteralPath $DllPath
$sourceDllHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
$winmmItem = Get-Item -LiteralPath $WinmmPath
$winmmHash = (Get-FileHash -LiteralPath $WinmmPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host '========== SOURCE RUNTIME ==========' -ForegroundColor Cyan
Write-Host "DLL    : $DllPath"
Write-Host "Taille : $($sourceDllItem.Length)"
Write-Host "SHA256 : $sourceDllHash"
Write-Host "winmm  : $WinmmPath"
Write-Host "SHA256 : $winmmHash"

if (-not $SkipGenerate) {
    Write-Host "========== GENERATION CLIENT/SERVER $Version ==========" -ForegroundColor Cyan
    Push-Location $launcherRoot
    try {
        foreach ($target in @('client', 'server')) {
            $publisherArgs = @(
                $publisher,
                '--dll', $DllPath,
                '--version', $Version,
                '--target', $target,
                '--changelist', [string]$Changelist,
                '--channel', $Channel,
                '--output', $updatesRoot,
                '--base-url', $BaseUrl.TrimEnd('/'),
                '--key', $SigningKeyPath,
                '--extra', $WinmmPath
            )
            & node @publisherArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Génération du feed '$target' échouée (code $LASTEXITCODE)."
            }
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host 'SkipGenerate actif : les artefacts existants vont être vérifiés puis ajoutés à Git.' -ForegroundColor Yellow
}

$feedInfo = @{}
foreach ($target in @('client', 'server')) {
    Write-Host "========== VERIFICATION FEED $target ==========" -ForegroundColor Cyan
    $feedRoot = Join-Path $runtimeRoot "$target\$Channel\$platform"
    $latestPath = Join-Path $feedRoot 'latest.json'
    $latest = Get-JsonFile $latestPath

    if ($latest.version -ne $Version) { throw "$target latest.json annonce $($latest.version), attendu $Version." }
    if ($latest.target -ne $target) { throw "$target latest.json cible '$($latest.target)' au lieu de '$target'." }
    if ($latest.channel -ne $Channel) { throw "$target latest.json canal '$($latest.channel)' au lieu de '$Channel'." }
    if ([int]$latest.targetChangelist -ne $Changelist) { throw "$target changelist incorrect : $($latest.targetChangelist)." }
    if ($latest.platform -ne $platform) { throw "$target plateforme incorrecte : $($latest.platform)." }

    $versionDir = Join-Path $feedRoot $Version
    $versionManifestPath = Join-Path $versionDir 'manifest.json'
    $null = Get-JsonFile $versionManifestPath

    $dllArtifact = Get-SafeArtifactPath -Directory $versionDir -Name ([string]$latest.file)
    Assert-FileHashAndSize -Path $dllArtifact -ExpectedHash ([string]$latest.sha256) -ExpectedSize ([long]$latest.size) -Description "$target runtime DLL"

    if ([long]$latest.size -ne $sourceDllItem.Length -or ([string]$latest.sha256).ToLowerInvariant() -ne $sourceDllHash) {
        throw "$target feed ne correspond pas à la DLL source compilée."
    }

    $extraNames = @()
    foreach ($extra in @($latest.extraFiles)) {
        $extraPath = Get-SafeArtifactPath -Directory $versionDir -Name ([string]$extra.name)
        Assert-FileHashAndSize -Path $extraPath -ExpectedHash ([string]$extra.sha256) -ExpectedSize ([long]$extra.size) -Description "$target extra $($extra.name)"
        if ([string]$extra.name -eq 'winmm.dll') {
            if ([long]$extra.size -ne $winmmItem.Length -or ([string]$extra.sha256).ToLowerInvariant() -ne $winmmHash) {
                throw "$target feed winmm.dll ne correspond pas au fichier source."
            }
        }
        $extraNames += [string]$extra.name
    }
    if ($extraNames -notcontains 'winmm.dll') { throw "$target feed ne référence pas winmm.dll." }

    $feedInfo[$target] = [pscustomobject]@{
        Root = $feedRoot
        VersionDir = $versionDir
        LatestPath = $latestPath
        DllPath = $dllArtifact
        DllHash = ([string]$latest.sha256).ToLowerInvariant()
        DllSize = [long]$latest.size
        ExtraNames = $extraNames
    }
}

if ($feedInfo.client.DllHash -ne $feedInfo.server.DllHash -or $feedInfo.client.DllSize -ne $feedInfo.server.DllSize) {
    throw 'Les feeds client et server ne contiennent pas la même DLL.'
}

Write-Host '========== VERIFICATION GIT ==========' -ForegroundColor Cyan
$branch = (& git -C $script:RepoRoot branch --show-current).Trim()
if ($CommitAndPush -and $branch -ne 'main') {
    throw "La publication distante est limitée à la branche main (branche actuelle : '$branch')."
}

$alreadyStaged = @(& git -C $script:RepoRoot diff --cached --name-only)
if ($LASTEXITCODE -ne 0) { throw 'Impossible de lire les fichiers déjà indexés par Git.' }
if ($alreadyStaged.Count -gt 0) {
    throw "L'index Git contient déjà des changements. Commit/stash-les avant publication :`n$($alreadyStaged -join "`n")"
}

foreach ($target in @('client', 'server')) {
    $info = $feedInfo[$target]
    $latestRelative = (Get-RepoRelativePath -Path $info.LatestPath)
    $versionRelative = (Get-RepoRelativePath -Path $info.VersionDir)
    # -f est indispensable : .gitignore contient *.dll. -A inclut tous les artefacts du dossier.
    Invoke-Git -GitArgs @('add', '-A', '-f', '--', $latestRelative, $versionRelative)
}

# Vérifie que chaque artefact présent dans les dossiers versionnés est réellement indexé.
foreach ($target in @('client', 'server')) {
    $info = $feedInfo[$target]
    $files = @(Get-ChildItem -LiteralPath $info.VersionDir -File -Recurse)
    if ($files.Count -lt 3) {
        throw "Le dossier $target/$Version contient trop peu de fichiers ($($files.Count)); DLL, manifest et extras attendus."
    }
    foreach ($file in $files) {
        $relative = (Get-RepoRelativePath -Path $file.FullName)
        & git -C $script:RepoRoot ls-files --error-unmatch -- $relative *> $null
        if ($LASTEXITCODE -ne 0) { throw "Artefact non suivi par Git après git add -f : $relative" }
    }
}

$staged = @(& git -C $script:RepoRoot diff --cached --name-only)
if ($LASTEXITCODE -ne 0) { throw 'Impossible de vérifier le contenu indexé.' }
$allowedRoots = @(
    "ParadoxBackend/updates/runtime/client/$Channel/$platform/",
    "ParadoxBackend/updates/runtime/server/$Channel/$platform/"
)
foreach ($path in $staged) {
    $allowed = $false
    foreach ($root in $allowedRoots) {
        if ($path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) { throw "Un fichier hors des feeds runtime est indexé : $path" }
}

Write-Host '========== FICHIERS INDEXES ==========' -ForegroundColor Cyan
$staged | ForEach-Object { Write-Host "  $_" }
Write-Host "Artefacts suivis : client + server $Version, DLL et extras inclus." -ForegroundColor Green

if ($CommitAndPush) {
    $hasChanges = $false
    & git -C $script:RepoRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 1) { $hasChanges = $true }
    elseif ($LASTEXITCODE -ne 0) { throw 'Échec de git diff --cached --quiet.' }

    if ($hasChanges) {
        $message = "Publish runtime $Version for client and server"
        Invoke-Git -GitArgs @('commit', '-m', $message)
    }
    else {
        Write-Host 'Aucun changement de feed à committer.' -ForegroundColor Yellow
    }
    Invoke-Git -GitArgs @('push', 'origin', 'main')
    Write-Host 'Publication Git poussée sur origin/main.' -ForegroundColor Green
}
else {
    Write-Host 'Artefacts vérifiés et indexés localement. Aucun commit/push effectué.' -ForegroundColor Yellow
    Write-Host 'Pour committer et pousser, relancer avec -CommitAndPush (après avoir vidé tout index existant si nécessaire).'
}
