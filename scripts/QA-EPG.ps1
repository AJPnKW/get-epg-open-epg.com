[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent), # repo root one level up
    [string]$PlaylistFile = "configs/playlist.m3u" # optional M3U for alignment
)

# Timestamped report file
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$OutputReport = Join-Path $ProjectRoot "logs/qa-report-$timestamp.txt"

$OutputDir   = Join-Path $ProjectRoot "data/output"
$ConfigDir   = Join-Path $ProjectRoot "configs"
$ScriptsDir  = Join-Path $ProjectRoot "scripts"
$WorkflowsDir= Join-Path $ProjectRoot ".github/workflows"

$report = @()

function Write-Report {
    param([string]$Line,[switch]$ConsoleOnly)
    $report += $Line
    if (-not $ConsoleOnly) { Write-Host $Line }
}

# --- 1. Key files ---
Write-Report "=== Key Files ==="
foreach ($dir in @($ScriptsDir,$WorkflowsDir,$ConfigDir)) {
    if (Test-Path $dir) {
        Get-ChildItem $dir -Recurse | ForEach-Object { Write-Report "$($_.FullName)" }
    } else {
        Write-Report "Missing directory: $dir"
    }
}

# --- 2. Version info ---
Write-Report "`n=== Version Info ==="
foreach ($file in Get-ChildItem $ScriptsDir -Filter *.ps1 -ErrorAction SilentlyContinue) {
    $firstLine = (Get-Content $file.FullName | Select-Object -First 1)
    Write-Report "$($file.Name): $firstLine"
}
foreach ($file in Get-ChildItem $WorkflowsDir -Filter *.yml -ErrorAction SilentlyContinue) {
    $firstLine = (Get-Content $file.FullName | Select-Object -First 1)
    Write-Report "$($file.Name): $firstLine"
}

# --- 3. Exclusion file ---
Write-Report "`n=== Input File Validation ==="
$excludeFile = Join-Path $ConfigDir "exclude_channels.txt"
$excludedChannels = @()
if (Test-Path $excludeFile) {
    $excludedChannels = Get-Content $excludeFile |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object {
            $_.Trim().ToLower() `
              -replace 'u00e9','é' `
              -replace 'u00e0','à' `
              -replace 'u00f1','ñ'
        }
    $exCount = $excludedChannels.Count
    Write-Report "Exclusion file exists with $exCount entries"
} else {
    Write-Report "Exclusion file MISSING"
}

function Is-Excluded($channel) {
    $c = $channel.Trim().ToLower()
    foreach ($ex in $excludedChannels) {
        if ($c -eq $ex) { return $true }
        if ($c -like $ex) { return $true }
    }
    return $false
}

# --- 4. QA each EPG file ---
$totalChannels = 0
$totalProgrammes = 0
$totalNoProg = 0
$totalOrphan = 0
$globalDates = @()

Write-Report "`n=== EPG File QA ==="
foreach ($epg in Get-ChildItem $OutputDir -Filter "open-epg-*.xml" -ErrorAction SilentlyContinue) {
    Write-Report "File: $($epg.Name)"
    try {
        [xml]$doc = Get-Content $epg.FullName
        $channels = $doc.tv.channel.Count
        $programmes = $doc.tv.programme.Count
        $sizeMB = [math]::Round((Get-Item $epg.FullName).Length / 1MB,2)
        Write-Report "  Size: ${sizeMB} MB"
        Write-Report "  Channels: $channels"
        Write-Report "  Programmes: $programmes"

        $totalChannels += $channels
        $totalProgrammes += $programmes

        $chanIDs = $doc.tv.channel.id
        $progIDs = $doc.tv.programme.channel

        # Channels with no programmes (excluding excluded list)
        $noProg = $chanIDs | Where-Object { $_ -notin $progIDs -and -not (Is-Excluded $_) }
        Write-Report "  Channels with NO programme data: $($noProg.Count)"
        $totalNoProg += $noProg.Count
        if ($noProg.Count -gt 0) {
            $noProg | Sort-Object | ForEach-Object { Write-Report "    $_" }
        }

        # Programmes with no channel (excluding excluded list)
        $orphanProg = $progIDs | Where-Object { $_ -notin $chanIDs -and -not (Is-Excluded $_) }
        Write-Report "  Programmes with NO matching channel: $($orphanProg.Count)"
        $totalOrphan += $orphanProg.Count
        if ($orphanProg.Count -gt 0) {
            $orphanProg | Sort-Object | Get-Unique | ForEach-Object { Write-Report "    $_" }
        }

        # Date range
        $dates = $doc.tv.programme.start | ForEach-Object {
            try { [datetime]::ParseExact($_.Substring(0,14),"yyyyMMddHHmmss",$null) } catch {}
        }
        if ($dates) {
            $minDate = ($dates | Measure-Object -Minimum).Minimum
            $maxDate = ($dates | Measure-Object -Maximum).Maximum
            $globalDates += $dates
            Write-Report "  Programme date range: $minDate to $maxDate"
        }

        # Density & duplicates
        $avgProgPerChannel = if ($channels -gt 0) { [math]::Round($programmes / $channels,2) } else { 0 }
        Write-Report "  Avg programmes per channel: $avgProgPerChannel"
        $dupChannels = $chanIDs | Group-Object | Where-Object { $_.Count -gt 1 -and -not (Is-Excluded $_.Name) }
        Write-Report "  Duplicate channel IDs detected: $($dupChannels.Count)"
        if ($dupChannels) {
            $dupChannels | ForEach-Object { Write-Report "    $($_.Name) appears $($_.Count)x" }
        }

        # --- Condensed gap detection ---
        $gapSummary = @{}
        $byChannel = $doc.tv.programme | Group-Object channel
        foreach ($grp in $byChannel) {
            if (-not (Is-Excluded $grp.Name)) {
                $times = $grp.Group.start | ForEach-Object {
                    try { [datetime]::ParseExact($_.Substring(0,14),"yyyyMMddHHmmss",$null) } catch {}
                }
                $sorted = $times | Sort-Object
                for ($i=1; $i -lt $sorted.Count; $i++) {
                    $gap = ($sorted[$i] - $sorted[$i-1]).TotalMinutes
                    if ($gap -gt 180) {
                        $dateKey = $sorted[$i-1].ToString("MM/dd/yyyy")
                        if (-not $gapSummary.ContainsKey($dateKey)) { $gapSummary[$dateKey] = @() }
                        if ($grp.Name -notin $gapSummary[$dateKey]) { $gapSummary[$dateKey] += $grp.Name }
                    }
                }
            }
        }

        if ($gapSummary.Count -gt 0) {
            Write-Report "  === GAP Summary (>3h) ==="
            foreach ($date in $gapSummary.Keys | Sort-Object) {
                Write-Report "  GAP > on channel for $date"
                $gapSummary[$date] | Sort-Object | ForEach-Object { Write-Report "    $_" }
            }
            # Top offenders
            $offenders = @{}
            foreach ($date in $gapSummary.Keys) {
                foreach ($ch in $gapSummary[$date]) {
                    if (-not $offenders.ContainsKey($ch)) { $offenders[$ch] = 0 }
                    $offenders[$ch]++
                }
            }
            $top10 = $offenders.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10
            Write-Report "  === Top 10 Channels with Most Gap Days ==="
            foreach ($entry in $top10) {
                Write-Report "    $($entry.Key): $($entry.Value) days"
            }
        }

    } catch {
        Write-Report "  ERROR parsing XML: $($_.Exception.Message)"
    }
}

# --- 5. Playlist alignment (optional) ---
$playlistPath = Join-Path $ProjectRoot $PlaylistFile
if (Test-Path $playlistPath) {
    Write-Report "`n=== Playlist Alignment ==="
    $playlistIDs = Select-String -Path $playlistPath -Pattern 'tvg-id="([^"]+)"' | ForEach-Object {
        $_.Matches.Groups[1].Value
    }
    foreach ($epg in Get-ChildItem $OutputDir -Filter "open-epg-*.xml" -ErrorAction SilentlyContinue) {
        [xml]$doc = Get-Content $epg.FullName
        $chanIDs = $doc.tv.channel.id
        $matched = $chanIDs | Where-Object { $_ -in $playlistIDs }
        $unmatched = $chanIDs | Where-Object { $_ -notin $playlistIDs }
        Write-Report "File: $($epg.Name)"
        Write-Report "  Channels matched to playlist: $($matched.Count)"
        Write-Report "  Channels NOT matched: $($unmatched.Count)"
        if ($unmatched.Count -gt 0) {
            $unmatched | Sort-Object | Select-Object -First 20 | ForEach-Object { Write-Report "    $_" }
            if ($unmatched.Count -gt 20) { Write-Report "    ... (truncated)" }
        }
    }
} else {
    Write-Report "`nPlaylist file not found ($PlaylistFile)"
}

# --- 6. Global summary ---
Write-Report "`n=== Global Summary ==="
Write-Report "Total channels across all files: $totalChannels"
Write-Report "Total programmes across all files: $totalProgrammes"
Write-Report "Channels with no programmes (all files): $totalNoProg"
Write-Report "Orphan programmes (all files): $totalOrphan"

if ($globalDates.Count -gt 0) {
    $globalMinDate = ($globalDates | Measure-Object -Minimum).Minimum
    $globalMaxDate = ($globalDates | Measure-Object -Maximum).Maximum
    Write-Report "Overall programme date range: $globalMinDate to $globalMaxDate"
}

# --- 7. Save report ---
$report | Out-File -FilePath $OutputReport -Encoding UTF8
Write-Host "QA report saved to $OutputReport"
