[CmdletBinding()]
param(
    [string[]] $Path,
    [string[]] $ScanRoot,
    [switch] $Launch,
    [int]    $Seconds = 45,
    [switch] $WhatIfOnly
)

if ($Path) {
    $Path = @($Path | ForEach-Object { $_ -split ';' } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().TrimEnd('\') })
}
if ($ScanRoot) {
    $ScanRoot = @($ScanRoot | ForEach-Object { $_ -split ';' } | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
        $r = $_.Trim().TrimEnd('\')
        if ($r -match '^[a-zA-Z]:?$') { "$($r.TrimEnd(':')):\"; return }
        $r
    })
}

$ErrorActionPreference = 'Continue'
$PluginDll  = Join-Path $PSScriptRoot 'GalleryUnlockPlugin.dll'
$LogName    = 'GalleryUnlock-report.txt'

function Write-Step  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Write-Info  ($m) { Write-Host "    [info] $m" -ForegroundColor Gray }
function Write-Warn2 ($m) { Write-Host "    [!]    $m" -ForegroundColor Yellow }
function Write-Bad   ($m) { Write-Host "    [X]    $m" -ForegroundColor Red }

function Test-GameFolder([string] $dir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }

    $managed = Get-ChildItem -LiteralPath $dir -Directory -Filter '*_Data' -ErrorAction SilentlyContinue |
               ForEach-Object { Join-Path $_.FullName 'Managed' } |
               Where-Object { Test-Path -LiteralPath $_ } |
               Select-Object -First 1
    if (-not $managed) { return $null }

    $naninovel = Join-Path $managed 'Elringus.Naninovel.Runtime.dll'
    if (-not (Test-Path -LiteralPath $naninovel)) { return $null }

    $asm = Get-ChildItem -LiteralPath $managed -Filter 'Assembly-CSharp.dll' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $asm) { return $null }

    $bytes = [System.IO.File]::ReadAllBytes($asm.FullName)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $hooks = @()
    if ($ascii -match 'UnlockableCustom') { $hooks += 'UnlockableCustom' }
    if ($ascii -match 'GalleryThumbnail')  { $hooks += 'GalleryThumbnail' }
    if ($hooks.Count -eq 0) { return $null }

    $exe = Get-ChildItem -LiteralPath $dir -Filter '*.exe' -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch 'CrashHandler|UnityCrash' } |
           Select-Object -First 1
    if (-not $exe) { return $null }

    $dataDir = Split-Path -Parent (Split-Path -Parent $asm.FullName)
    $appInfo = Join-Path $dataDir 'app.info'

    [pscustomobject]@{
        Dir          = $dir
        Exe          = $exe.FullName
        ExeName      = $exe.Name
        ManagedDir   = $managed
        BepInExDir   = Join-Path $dir 'BepInEx'
        AppInfo      = if (Test-Path -LiteralPath $appInfo) { Get-Content -LiteralPath $appInfo -Raw } else { '' }
        PluginPath   = Join-Path $dir 'BepInEx\plugins\GalleryUnlockPlugin.dll'
        Hooks        = $hooks
    }
}

function Get-ScanTargets {
    if ($ScanRoot) { return $ScanRoot }
    return (Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Free -ne $null -and (Test-Path "$($_.Root)") } |
            ForEach-Object { $_.Root })
}

function Find-Games {
    param([string[]] $Roots)

    $found = New-Object System.Collections.Generic.List[object]
    $seen  = @{}

    foreach ($root in $Roots) {
        Write-Info "scanning $root ..."
        $candidates = @()
        try {
            $candidates = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue
        } catch { }

        foreach ($c in $candidates) {
            if ($seen.ContainsKey($c.FullName)) { continue }
            $seen[$c.FullName] = $true

            $g = Test-GameFolder $c.FullName
            if ($g) {
                $found.Add($g)
                Write-Ok "found: $($g.Dir)"
            }
        }
    }
    return $found
}

function Get-SaveState($game) {
    $localLow = Join-Path $env:USERPROFILE 'AppData\LocalLow'
    $hits = @()

    $company = $null; $product = $null
    foreach ($line in ($game.AppInfo -split "`n")) {
        $t = $line.Trim()
        if ($t -match '^(.*?)(?:company|Company)\s*:\s*(.+)$') { $company = $Matches[2].Trim() }
        if ($t -match '^(.*?)(?:product|Product)\s*:\s*(.+)$') { $product = $Matches[2].Trim() }
    }
    if (-not $product) { $product = [System.IO.Path]::GetFileNameWithoutExtension($game.ExeName) }

    $candidates = @()
    if ($company) {
        $candidates += Join-Path $localLow (Join-Path $company $product)
    }
    $candidates += (Get-ChildItem -LiteralPath $localLow -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match 'NTRMAN|Naninovel|SeasonsOfLoss' } |
                   ForEach-Object { Join-Path $_.FullName $product })

    foreach ($c in ($candidates | Select-Object -Unique)) {
        $saveDir = Join-Path $c 'NaninovelData\Saves'
        if (Test-Path -LiteralPath $saveDir) {
            $gs = Join-Path $saveDir 'GlobalSave.nson'
            $hits += [pscustomobject]@{
                SaveDir = $saveDir
                Global  = (Test-Path -LiteralPath $gs)
                Slots   = @(Get-ChildItem -LiteralPath $saveDir -Filter '*.nson' -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -ne 'GlobalSave.nson' }).Count
            }
        }
    }
    return $hits
}

function Get-PEBitness([string] $file) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $fs = [System.IO.File]::OpenRead($file)
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $pe = $br.ReadInt32()
        $fs.Position = $pe + 4
        $m = $br.ReadUInt16()
        $br.Close(); $fs.Close()
        if ($m -eq 0x14c) { return 'x86' }
        if ($m -eq 0x8664) { return 'x64' }
        return 'unknown'
    } catch { return $null }
}

function Install-BepInEx($game) {
    $coreDll  = Join-Path $game.BepInExDir 'core\BepInEx.dll'
    $shimPath = Join-Path $game.Dir 'winhttp.dll'

    $exeBits  = Get-PEBitness $game.Exe
    $shimBits = Get-PEBitness $shimPath

    if ($exeBits -eq $null) {
        Write-Bad "cannot read PE header of $($game.ExeName)"
        return $false
    }

    if ((Test-Path -LiteralPath $coreDll) -and $shimBits -eq $exeBits) {
        return $true
    }

    $payload = if ($exeBits -eq 'x86') { Join-Path $PSScriptRoot 'bepinex_x86' }
               else                 { Join-Path $PSScriptRoot 'bepinex' }

    $payloadCore = Join-Path $payload 'core'
    if (-not (Test-Path -LiteralPath $payloadCore)) {
        Write-Bad "no bundled BepInEx payload for $exeBits at: $payload"
        return $false
    }

    $il2cpp = @(Get-ChildItem -LiteralPath $game.Dir -Recurse -Filter 'GameAssembly.dll' -ErrorAction SilentlyContinue).Count -gt 0
    if ($il2cpp) {
        Write-Bad 'game is IL2CPP - this Mono BepInEx payload will not work, skipping'
        return $false
    }
    if ($game.ManagedDir -and -not (Test-Path -LiteralPath $game.ManagedDir)) {
        Write-Bad 'no Managed folder found, cannot confirm this is a Mono build'
        return $false
    }

    if ($shimBits -and $shimBits -ne $exeBits) {
        Write-Warn2 "existing loader shim is $shimBits but the game is $exeBits - reinstalling"
    }

    if ($WhatIfOnly) {
        Write-Info "[whatif] would install $exeBits BepInEx into $($game.Dir)"
        return $true
    }

    if ($shimBits -and $shimBits -ne $exeBits) {
        $bak = "$shimPath.wrongbits"
        if (-not (Test-Path -LiteralPath $bak)) {
            Move-Item -LiteralPath $shimPath -Destination $bak -Force
            Write-Info "moved mismatched shim -> $(Split-Path -Leaf $bak)"
        } else {
            Remove-Item -LiteralPath $shimPath -Force
        }
    }

    try {
        if (Test-Path -LiteralPath $game.BepInExDir) {
            Remove-Item -LiteralPath $game.BepInExDir -Recurse -Force
        }
        Copy-Item -LiteralPath $payload -Destination $game.BepInExDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $payload 'winhttp.dll')         -Destination $shimPath -Force
        Copy-Item -LiteralPath (Join-Path $payload 'doorstop_config.ini') -Destination (Join-Path $game.Dir 'doorstop_config.ini') -Force
        Write-Ok "BepInEx installed ($exeBits Mono payload)"
        return $true
    } catch {
        Write-Bad "BepInEx install failed: $($_.Exception.Message)"
        return $false
    }
}

function Install-Plugin($game) {
    if (-not (Install-BepInEx $game)) {
        Write-Info 'install a matching BepInEx 5 build into that folder manually, then re-run.'
        return $false
    }

    $plugins = Join-Path $game.BepInExDir 'plugins'
    if (-not (Test-Path -LiteralPath $plugins)) {
        Write-Warn2 'no plugins folder yet, will be created'
    }

    if ($WhatIfOnly) {
        Write-Info "[whatif] would copy plugin -> $($game.PluginPath)"
        return $true
    }

    if (-not (Test-Path -LiteralPath $PluginDll)) {
        Write-Bad "plugin dll missing next to this script: $PluginDll"
        return $false
    }

    if (-not (Test-Path -LiteralPath $plugins)) {
        New-Item -ItemType Directory -Path $plugins -Force | Out-Null
    }

    $running = Get-Process -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -eq $game.Exe }
    foreach ($r in $running) {
        Write-Info "stopping running instance $($r.ProcessName) ..."
        try { $r.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 3
              if (-not $r.HasExited) { $r.Kill() } } catch { }
    }

    Copy-Item -LiteralPath $PluginDll -Destination $game.PluginPath -Force
    Write-Ok "plugin installed -> $($game.PluginPath)"

    $cfgDir = Join-Path $game.BepInExDir 'config'
    if (Test-Path -LiteralPath $cfgDir) {
        $cfg = Join-Path $cfgDir 'ntrman.seasonsofloss.galleryunlock.cfg'
        if (Test-Path -LiteralPath $cfg) {
            $c = Get-Content -LiteralPath $cfg
            ($c -replace '(?m)^Enabled\s*=\s*\w+', 'Enabled = true') |
                Set-Content -LiteralPath $cfg
            Write-Ok "config forced Enabled = true"
        }
    }
    return $true
}

function Test-UnlockLive($game) {
    $log = Join-Path $game.BepInExDir 'LogOutput.log'
    if (Test-Path -LiteralPath $log) { Set-Content -LiteralPath $log -Value '' -NoNewline }

    $cfg = Join-Path $game.BepInExDir 'config\ntrman.seasonsofloss.galleryunlock.cfg'
    if (Test-Path -LiteralPath $cfg) {
        (Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue) -replace '(?m)^Verbose\s*=\s*\w+', 'Verbose = true' |
            Set-Content -LiteralPath $cfg
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfg) -Force | Out-Null
        "[General]`r`nEnabled = true`r`nVerbose = true`r`n" | Set-Content -LiteralPath $cfg
        Write-Info 'created a fresh config with Verbose = true for this test'
    }

    Write-Info "launching $($game.ExeName) for $Seconds s ..."
    $p = Start-Process -FilePath $game.Exe -WorkingDirectory $game.Dir -PassThru -ErrorAction SilentlyContinue
    if (-not $p) { Write-Bad 'failed to start the game'; return $false }

    Start-Sleep -Seconds $Seconds
    if (-not $p.HasExited) {
        try { $p.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 3 } catch { }
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    }
    Start-Sleep -Seconds 2

    if (Test-Path -LiteralPath $cfg) {
        (Get-Content -LiteralPath $cfg -Raw) -replace '(?m)^Verbose\s*=\s*\w+', 'Verbose = false' |
            Set-Content -LiteralPath $cfg
    }

    if (-not (Test-Path -LiteralPath $log)) { Write-Bad 'no BepInEx log produced'; return $false }

    $text = Get-Content -LiteralPath $log -Raw
    $loaded  = $text -match 'NTRMAN Gallery Unlocker\] Loaded\.'
    $skipped = $text -match 'Skipping \[NTRMAN Gallery Unlocker\]'
    $found   = ([regex]::Matches($text, 'Discovered gallery unlock id: (\S+)') |
                ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $persisted = $text -match 'written to the global save'
    $noSaveApi = $text -match 'no known global-save method'
    $saveFail  = $text -match 'Could not write the global save|IStateManager was unavailable'
    $errors    = ([regex]::Matches($text, '(?m)^\[(Error|Fatal)') ).Count

    if ($skipped) {
        Write-Bad 'plugin was SKIPPED by BepInEx process filters - rebuild the plugin without BepInProcess'
        return $false
    }
    if ($loaded) { Write-Ok 'plugin initialised in-game' }
    else {
        Write-Bad 'plugin did NOT initialise (BepInEx may not have loaded at all)'
        return $false
    }

    if ($errors -gt 0) {
        Write-Warn2 "$errors error line(s) in the BepInEx log - check $($game.BepInExDir)\LogOutput.log"
    }

    if ($found.Count -gt 0) {
        Write-Ok "unlock ids confirmed in-game: $($found.Count)"
        $found | Sort-Object | ForEach-Object { Write-Info "  $_" }
    } else {
        Write-Warn2 'no unlock ids discovered (the Gallery screen was probably never opened)'
    }

    if ($persisted) { Write-Ok 'unlock flags written to global save (persists across runs)' }
    elseif ($noSaveApi) { Write-Warn2 'this Naninovel build has no global-save API - unlock re-applies every launch only' }
    elseif ($saveFail)  { Write-Warn2 'could not write the global save - unlock re-applies every launch only' }
    else { Write-Info 'nothing to write - gallery was already unlocked from an earlier run' }

    return $loaded
}

Write-Host ''
Write-Host '  NTRMAN Gallery Unlocker' -ForegroundColor White
Write-Host '  -----------------------' -ForegroundColor White

if (-not (Test-Path -LiteralPath $PluginDll)) {
    Write-Bad "GalleryUnlockPlugin.dll not found next to this script ($PSScriptRoot)."
    exit 1
}

$games = @()
if ($Path) {
    foreach ($p in $Path) {
        $g = Test-GameFolder $p
        if ($g) { $games += $g } else { Write-Warn2 "not a matching Naninovel gallery game: $p" }
    }
    if ($games.Count -eq 0) { Write-Bad 'no matching game found'; exit 1 }
} else {
    $games = @(Find-Games -Roots (Get-ScanTargets))
    if ($games.Count -eq 0) {
        Write-Warn2 'no matching game found on this machine.'
        Write-Info 'pass -Path "<game folder>" to point at one directly.'
        exit 1
    }
}

Write-Host ''
Write-Step "matched $($games.Count) game(s)"

$report = New-Object System.Collections.Generic.List[string]
$allOk = $true

foreach ($g in $games) {
    Write-Host ''
    Write-Host "--- $($g.Dir)" -ForegroundColor Yellow
    $report.Add("=== $($g.Dir)")

    Write-Info "exe: $($g.ExeName)"
    Write-Info "gallery hook(s): $($g.Hooks -join ', ')"
    if ($g.AppInfo) { Write-Info "app.info: $($g.AppInfo -replace '[\r\n]+',' ')" }

    $saves = @(Get-SaveState $g)
    if ($saves.Count -eq 0) {
        Write-Warn2 'no Naninovel save found -> game looks unplayed (gallery fully locked)'
        $report.Add('  state: no save (fully locked)')
    } else {
        foreach ($s in $saves) {
            if ($s.Global) {
                Write-Info "global save present: $($s.SaveDir)"
                Write-Info "game slots: $($s.Slots)"
                Write-Warn2 'save is Naninovel-encrypted, flags cannot be read offline'
                $report.Add("  state: global save present, slots=$($s.Slots) (encrypted)")
            } else {
                Write-Info "save dir (no GlobalSave.nson): $($s.SaveDir)"
                $report.Add('  state: save dir present, no global save')
            }
        }
    }

    if (Install-Plugin $g) {
        $report.Add('  install: ok')
        if ($Launch -and -not $WhatIfOnly) {
            if (Test-UnlockLive $g) { $report.Add('  verify: passed') }
            else                    { $report.Add('  verify: FAILED'); $allOk = $false }
        } else {
            Write-Info 're-run with -Launch to verify live in-game'
        }
    } else {
        $report.Add('  install: FAILED')
        $allOk = $false
    }
}

Write-Host ''
if ($Launch -or $WhatIfOnly) {
    Write-Step 'summary'
    $report | ForEach-Object { Write-Host "  $_" }
}

$reportPath = Join-Path $PSScriptRoot $LogName
try {
    ($report -join "`r`n") | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host ''
    Write-Info "report: $reportPath"
} catch { }

Write-Host ''
if ($allOk) {
    Write-Host 'Done. Gallery is unlocked once the game is run.' -ForegroundColor Green
} else {
    Write-Host 'Finished with issues - see report above.' -ForegroundColor Yellow
}
Write-Host ''