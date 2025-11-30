<#
.SYNOPSIS
  Fetches multiple XMLTV EPG feeds from open-epg.com with menu-driven run options.
  Prefers .xml.gz with smart fallback to .xml, logs all activity with timestamps,
  merges into a single deduplicated XMLTV file (open-epg.xml), emits per-region
  summary JSON, and validates structure with anomaly reporting.

.DESCRIPTION
  - Interactive menu by default.
  - NonInteractive mode via parameter for scheduling.
  - Multithreaded downloads (PowerShell 7+).
  - Logging with timestamps and levels.
  - Spinner for visible activity.
  - Dedup logic includes desc to reduce collisions.
  - QA validation and anomaly reporting.
  - Summary JSON for monitoring.

.PARAMETER NonInteractive
  Run pipeline directly without menu (for scheduling).

.PARAMETER CleanFirst
  Clean downloads/work directories before run.

.NOTES
  Version: 1.2.0
  Author: Andrew (AJPnKW)
  Repo: https://github.com/AJPnKW/get-epg-open-epg.com
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$CleanFirst
)

# ----------------------------
# Paths and configuration
# ----------------------------
$ProjectRoot = "C:\Users\Lenovo\PROJECTS\get-epg-open-epg.com\get-epg-open-epg.com"
$ScriptsDir  = Join-Path $ProjectRoot "scripts"
$DataDir     = Join-Path $ProjectRoot "data"
$Downloads   = Join-Path $DataDir "downloads"
$WorkDir     = Join-Path $DataDir "work"
$OutputDir   = Join-Path $DataDir "output"
$LogsDir     = Join-Path $ProjectRoot "logs"

$LogFile     = Join-Path $LogsDir "open-epg.log.txt"
$OutputFile  = Join-Path $OutputDir "open-epg.xml"
$SummaryFile = Join-Path $OutputDir "summary.json"

# Defaults (can be adjusted in menu)
$Global:MaxParallel = 8
$Global:VerboseMode = $false

# Ensure folder structure
$null = New-Item -ItemType Directory -Force -Path $ScriptsDir, $DataDir, $Downloads, $WorkDir, $OutputDir, $LogsDir

# ----------------------------
# Logging helpers
# ----------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level = 'INFO'
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "{0} [{1}] {2}" -f $timestamp, $Level, $Message
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'DEBUG' { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
}

# Spinner (visual activity indicator)
$script:SpinnerFrames = @('|','/','-','\')
$script:SpinnerIndex = 0
function Show-Spinner {
    param([string]$Activity = "Working")
    $frame = $script:SpinnerFrames[$script:SpinnerIndex % $script:SpinnerFrames.Count]
    $script:SpinnerIndex++
    Write-Host ("[{0}] {1}" -f $frame, $Activity) -NoNewline
    Start-Sleep -Milliseconds 80
    Write-Host "`r" -NoNewline
}

# ----------------------------
# Source list (prefer .xml.gz, fallback to .xml)
# ----------------------------
$Sources = @(
    @{ Name='Australia 1'; Region='Australia'; Gz='https://www.open-epg.com/files/australia1.xml.gz'; Xml='https://www.open-epg.com/files/australia1.xml' },
    @{ Name='Australia 2'; Region='Australia'; Gz='https://www.open-epg.com/files/australia2.xml.gz'; Xml='https://www.open-epg.com/files/australia2.xml' },
    @{ Name='Australia 3'; Region='Australia'; Gz='https://www.open-epg.com/files/australia3.xml.gz'; Xml='https://www.open-epg.com/files/australia3.xml' },
    @{ Name='Australia 4'; Region='Australia'; Gz='https://www.open-epg.com/files/australia4.xml.gz'; Xml='https://www.open-epg.com/files/australia4.xml' },

    @{ Name='Canada 1';   Region='Canada';     Gz='https://www.open-epg.com/files/canada1.xml.gz';    Xml='https://www.open-epg.com/files/canada1.xml' },
    @{ Name='Canada 2';   Region='Canada';     Gz='https://www.open-epg.com/files/canada2.xml.gz';    Xml='https://www.open-epg.com/files/canada2.xml' },
    @{ Name='Canada 3';   Region='Canada';     Gz='https://www.open-epg.com/files/canada3.xml.gz';    Xml='https://www.open-epg.com/files/canada3.xml' },
    @{ Name='Canada 4';   Region='Canada';     Gz='https://www.open-epg.com/files/canada4.xml.gz';    Xml='https://www.open-epg.com/files/canada4.xml' },
    @{ Name='Canada 5';   Region='Canada';     Gz='https://www.open-epg.com/files/canada5.xml.gz';    Xml='https://www.open-epg.com/files/canada5.xml' },
    @{ Name='Canada 6';   Region='Canada';     Gz='https://www.open-epg.com/files/canada6.xml.gz';    Xml='https://www.open-epg.com/files/canada6.xml' },

    @{ Name='United States 1'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates1.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates1.xml' },
    @{ Name='United States 2'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates2.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates2.xml' },
    @{ Name='United States 3'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates3.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates3.xml' },
    @{ Name='United States 4'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates4.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates4.xml' },
    @{ Name='United States 5'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates5.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates5.xml' },
    @{ Name='United States 6'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates6.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates6.xml' },
    @{ Name='United States 7'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates7.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates7.xml' },
    @{ Name='United States 8'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates8.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates8.xml' },
    @{ Name='United States 9'; Region='United States'; Gz='https://www.open-epg.com/files/unitedstates9.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates9.xml' },

    @{ Name='United Kingdom 1'; Region='United Kingdom'; Gz='https://www.open-epg.com/files/unitedkingdom1.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom1.xml' },
    @{ Name='United Kingdom 2'; Region='United Kingdom'; Gz='https://www.open-epg.com/files/unitedkingdom2.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom2.xml' },
    @{ Name='United Kingdom 3'; Region='United Kingdom'; Gz='https://www.open-epg.com/files/unitedkingdom3.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom3.xml' },
    @{ Name='United Kingdom 4'; Region='United Kingdom'; Gz='https://www.open-epg.com/files/unitedkingdom4.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom4.xml' },
    @{ Name='United Kingdom 5'; Region='United Kingdom'; Gz='https://www.open-epg.com/files/unitedkingdom5.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom5.xml' }
)

# ----------------------------
# Utilities
# ----------------------------
function Normalize-Url {
    param([string]$Url)
    if ($Url -match '^(https?://)(.+)$') {
        $proto = $matches[1]; $rest = $matches[2]
        $rest = $rest -replace '//+', '/'
        return "$proto$rest"
    }
    return $Url
}

function Clean-WorkDirs {
    Write-Log "[Init] Cleaning downloads/work directories" 'INFO'
    Get-ChildItem -Path $Downloads -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $WorkDir   -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ----------------------------
# Download with fallback (.gz -> .xml)
# ----------------------------
function Download-AllSources {
    Write-Log "[Init] Starting downloads (max parallel: $Global:MaxParallel)" 'INFO'

    $downloadResults = $Sources | ForEach-Object -Parallel {
        param($Downloads)
        # Inline helpers for parallel runspace
        function Normalize-Url {
            param([string]$Url)
            if ($Url -match '^(https?://)(.+)$') {
                $proto = $matches[1]; $rest = $matches[2]
                $rest = $rest -replace '//+', '/'
                return "$proto$rest"
            }
            return $Url
        }

        $name   = $_.Name
        $gzUrl  = Normalize-Url $_.Gz
        $xmlUrl = Normalize-Url $_.Xml
        $safe   = ($name -replace '\s+', '_').ToLower()

        $targetGz  = Join-Path $Downloads ("{0}.xml.gz" -f $safe)
        $targetXml = Join-Path $Downloads ("{0}.xml"    -f $safe)

        $result = [ordered]@{
            Name        = $name
            Region      = $_.Region
            SourceUrl   = $null
            OutputFile  = $null
            Status      = 'Unknown'
            Bytes       = 0
            Error       = $null
        }

        try {
            Invoke-WebRequest -Uri $gzUrl -OutFile $targetGz -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $result.SourceUrl  = $gzUrl
            $result.OutputFile = $targetGz
            $result.Status     = 'DownloadedGz'
            $result.Bytes      = (Get-Item $targetGz).Length
        }
        catch {
            try {
                Invoke-WebRequest -Uri $xmlUrl -OutFile $targetXml -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                $result.SourceUrl  = $xmlUrl
                $result.OutputFile = $targetXml
                $result.Status     = 'DownloadedXml'
                $result.Bytes      = (Get-Item $targetXml).Length
            }
            catch {
                $result.Status = 'Failed'
                $result.Error  = $_.Exception.Message
            }
        }
        $result
    } -ArgumentList $Downloads -ThrottleLimit $Global:MaxParallel

    foreach ($dr in $downloadResults) {
        switch ($dr.Status) {
            'DownloadedGz'  { Write-Log "[$($dr.Name)] OK .gz ($($dr.Bytes) bytes): $($dr.SourceUrl)" 'INFO' }
            'DownloadedXml' { Write-Log "[$($dr.Name)] OK .xml ($($dr.Bytes) bytes): $($dr.SourceUrl)" 'INFO' }
            'Failed'        { Write-Log "[$($dr.Name)] FAILED: $($dr.Error)" 'ERROR' }
            default         { Write-Log "[$($dr.Name)] Unknown status" 'WARN' }
        }
        Show-Spinner -Activity "Downloading"
    }

    return $downloadResults
}

# ----------------------------
# Decompress .gz files where applicable
# ----------------------------
function Expand-GzipIfNeeded {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputDir
    )

    $outXml = [System.IO.Path]::ChangeExtension((Join-Path $OutputDir ([System.IO.Path]::GetFileName($InputPath))), ".xml")
    $info = [ordered]@{
        Input      = $InputPath
        OutputXml  = $outXml
        Status     = 'Skipped'
        BytesIn    = 0
        BytesOut   = 0
        Error      = $null
    }

    try {
        if ($InputPath.ToLower().EndsWith(".gz")) {
            Write-Log "[Decompress] $InputPath -> $outXml" 'INFO'
            $info.BytesIn = (Get-Item $InputPath).Length
            $inStream  = [System.IO.File]::OpenRead($InputPath)
            try {
                $gzip      = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                $outStream = [System.IO.File]::Create($outXml)
                try {
                    $buffer = New-Object byte[] 8192
                    while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $outStream.Write($buffer, 0, $read)
                        Show-Spinner -Activity "Decompressing"
                    }
                }
                finally {
                    $outStream.Dispose()
                    $gzip.Dispose()
                }
            }
            finally {
                $inStream.Dispose()
            }

            $info.Status   = 'Decompressed'
            $info.BytesOut = (Get-Item $outXml).Length
            Write-Log "[Decompress] Done ($($info.BytesIn) -> $($info.BytesOut) bytes)" 'INFO'
        }
        else {
            $info.Status = 'AlreadyXml'
            $info.OutputXml = $InputPath
        }
    }
    catch {
        $info.Status = 'Failed'
        $info.Error  = $_.Exception.Message
        Write-Log "[Decompress] Failed: $($info.Error)" 'ERROR'
    }
    return $info
}

# ----------------------------
# Merge XMLTV with stronger dedup (title + desc)
# Key:
#   channel: @id
#   programme: channel|start|stop|title|desc
# ----------------------------
function Merge-XmlTv {
    param(
        [Parameter(Mandatory)][object[]]$ProcessedFiles, # { Path, Region }
        [Parameter(Mandatory)][string]$OutputFile
    )

    Write-Log "[Merge] Starting merge of $($ProcessedFiles.Count) files" 'INFO'

    $rootDoc = New-Object System.Xml.XmlDocument
    $decl = $rootDoc.CreateXmlDeclaration("1.0","UTF-8",$null)
    $rootDoc.AppendChild($decl) | Out-Null
    $tv = $rootDoc.CreateElement("tv")
    $tv.SetAttribute("generator-info-name","open-epg-merge")
    $tv.SetAttribute("generator-info-url","https://github.com/AJPnKW/get-epg-open-epg.com")
    $null = $rootDoc.AppendChild($tv)

    $channelIds = New-Object System.Collections.Generic.HashSet[string]
    $programmeKeys = New-Object System.Collections.Generic.HashSet[string]

    $totalChannels = 0
    $totalProgrammes = 0
    $dupChannels = 0
    $dupProgrammes = 0

    # Region summary counters
    $regionSummary = @{}

    foreach ($pf in $ProcessedFiles) {
        $file = $pf.Path
        $region = $pf.Region
        if (-not (Test-Path $file)) {
            Write-Log "[Merge] Missing file: $file" 'WARN'
            continue
        }

        try {
            Write-Log "[Merge] Parsing: $file ($region)" 'INFO'
            [xml]$doc = Get-Content -Path $file -Raw
            if ($null -eq $doc.tv) {
                Write-Log "[Merge] Invalid XMLTV structure (no <tv>): $file" 'WARN'
                continue
            }

            if (-not $regionSummary.ContainsKey($region)) {
                $regionSummary[$region] = [ordered]@{ Channels=0; Programmes=0 }
            }

            foreach ($ch in $doc.tv.channel) {
                $id = $ch.id
                if ([string]::IsNullOrWhiteSpace($id)) {
                    Write-Log "[Merge] Channel without id in $file; skipping." 'WARN'
                    continue
                }
                if ($channelIds.Add($id)) {
                    $imported = $rootDoc.ImportNode($ch, $true)
                    $tv.AppendChild($imported) | Out-Null
                    $totalChannels++
                    $regionSummary[$region].Channels++
                }
                else {
                    $dupChannels++
                }
            }

            foreach ($pg in $doc.tv.programme) {
                $chid  = $pg.channel
                $start = $pg.start
                $stop  = $pg.stop
                $title = ($pg.title | ForEach-Object { $_.'#text' }) -join '' # handle localized nodes
                $desc  = ($pg.desc  | ForEach-Object { $_.'#text' }) -join ''

                $key = "{0}|{1}|{2}|{3}|{4}" -f ($chid ?? ''), ($start ?? ''), ($stop ?? ''), ($title ?? '').Trim(), ($desc ?? '').Trim()

                if ($programmeKeys.Add($key)) {
                    $imported = $rootDoc.ImportNode($pg, $true)
                    $tv.AppendChild($imported) | Out-Null
                    $totalProgrammes++
                    $regionSummary[$region].Programmes++
                }
                else {
                    $dupProgrammes++
                }
            }

            Show-Spinner -Activity "Merging"
        }
        catch {
            Write-Log "[Merge] Failed to parse/merge $file: $($_.Exception.Message)" 'ERROR'
            continue
        }
    }

    try {
        Write-Log "[Merge] Writing output: $OutputFile" 'INFO'
        $rootDoc.Save($OutputFile)
        Write-Log "[Merge] Complete: Channels=$totalChannels (+$dupChannels dup), Programmes=$totalProgrammes (+$dupProgrammes dup)" 'INFO'
    }
    catch {
        Write-Log "[Merge] Failed to write output: $($_.Exception.Message)" 'ERROR'
        throw
    }

    return $regionSummary
}

# ----------------------------
# Validation and anomaly reporting
# ----------------------------
function Validate-XmlTv {
    param([Parameter(Mandatory)][string]$XmlPath)
    $issues = @()
    $warns  = @()

    try {
        [xml]$doc = Get-Content -Path $XmlPath -Raw
        if ($null -eq $doc.tv) { $issues += "Missing <tv> root" }

        $channels = @($doc.tv.channel)
        $programmes = @($doc.tv.programme)

        $channelCount = ($channels | Measure-Object).Count
        $programmeCount = ($programmes | Measure-Object).Count
        if ($channelCount -eq 0) { $warns += "No channels found" }
        if ($programmeCount -eq 0) { $warns += "No programmes found" }

        # Required programme attributes and time format sanity
        $badAttrs = 0
        $badTimes = 0
        foreach ($pg in $programmes) {
            if ([string]::IsNullOrWhiteSpace($pg.channel) -or
                [string]::IsNullOrWhiteSpace($pg.start)  -or
                [string]::IsNullOrWhiteSpace($pg.stop)) {
                $badAttrs++
                continue
            }

            # XMLTV time usually yyyymmddhhmmss Z or offset; naive checks
            if ($pg.start -notmatch '^\d{14}' -or $pg.stop -notmatch '^\d{14}') { $badTimes++ }
        }

        if ($badAttrs -gt 0) { $issues += "Programmes missing required attributes: $badAttrs" }
        if ($badTimes -gt 0) { $warns  += "Programmes with non-standard time formats: $badTimes" }

        Write-Log "[QA] Channels=$channelCount; Programmes=$programmeCount" 'INFO'
    }
    catch {
        $issues += "Cannot parse XML: $($_.Exception.Message)"
    }

    foreach ($i in $issues) { Write-Log "[QA] Issue: $i" 'WARN' }
    foreach ($w in $warns)  { Write-Log "[QA] Note: $w" 'DEBUG' }

    if ($issues.Count -eq 0) {
        Write-Log "[QA] Validation passed (no critical issues)" 'INFO'
    }
}

# ----------------------------
# Emit per-region summary JSON
# ----------------------------
function Write-RegionSummaryJson {
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$Path
    )
    $obj = @()
    foreach ($k in $Summary.Keys) {
        $obj += [ordered]@{
            Region     = $k
            Channels   = $Summary[$k].Channels
            Programmes = $Summary[$k].Programmes
        }
    }
    $json = $obj | ConvertTo-Json -Depth 3
    Set-Content -Path $Path -Value $json -Encoding UTF8
    Write-Log "[Summary] JSON written: $Path" 'INFO'
}

# ----------------------------
# Orchestrated run
# ----------------------------
function Run-Pipeline {
    param(
        [switch]$CleanFirst
    )

    Write-Log "===== START Open-EPG Merge Run =====" 'INFO'
    try {
        if ($CleanFirst) { Clean-WorkDirs }

        $downloadResults = Download-AllSources

        # Decompress and collect processed paths with region
        Write-Log "[Init] Decompressing gz files (if any)" 'INFO'
        $toProcess = @()
        foreach ($dr in $downloadResults) {
            if ($dr.Status -in @('DownloadedGz','DownloadedXml')) {
                $info = Expand-GzipIfNeeded -InputPath $dr.OutputFile -OutputDir $WorkDir
                if ($info.Status -in @('Decompressed','AlreadyXml')) {
                    $toProcess += @{ Path = $info.OutputXml; Region = $dr.Region }
                }
            }
            else {
                Write-Log "[Init] Skipping due to previous failure: $($dr.Name)" 'WARN'
            }
        }

        if ($toProcess.Count -gt 0) {
            $summary = Merge-XmlTv -ProcessedFiles $toProcess -OutputFile $OutputFile
            Validate-XmlTv -XmlPath $OutputFile
            Write-RegionSummaryJson -Summary $summary -Path $SummaryFile

            Write-Log "[Done] Output saved: $OutputFile" 'INFO'
            Write-Log "[Done] Summary saved: $SummaryFile" 'INFO'
            Write-Host ""
            Write-Host "========================================================="
            Write-Host "Open EPG merge complete."
            Write-Host "Output: $OutputFile"
            Write-Host "Summary: $SummaryFile"
            Write-Host "Log:    $LogFile"
            Write-Host "========================================================="
        }
        else {
            Write-Log "[Init] No processed XML files available to merge" 'ERROR'
            Write-Host ""
            Write-Host "No XML files to merge. Check logs for errors."
        }
    }
    catch {
        Write-Log "[Fatal] Unhandled error: $($_.Exception.Message)" 'ERROR'
    }
    finally {
        Write-Log "===== END Open-EPG Merge Run =====" 'INFO'
    }
}

# ----------------------------
# Interactive menu
# ----------------------------
function Show-Menu {
    Clear-Host
    Write-Host "==============================================="
    Write-Host " Open EPG Fetch & Merge - Interactive Menu"
    Write-Host "==============================================="
    Write-Host ""
    Write-Host "Choose an option (enter number):"
    Write-Host ""
    Write-Host " 1) Normal Run"
    Write-Host "    - Download (pref .gz, fallback .xml), decompress, merge, validate,"
    Write-Host "      emit summary JSON. Uses current MaxParallel=$Global:MaxParallel."
    Write-Host ""
    Write-Host " 2) Clean Run"
    Write-Host "    - Same as Normal Run but first cleans downloads/work folders."
    Write-Host "      Use if prior partial runs or corrupted temp files suspected."
    Write-Host ""
    Write-Host " 3) Advanced Settings"
    Write-Host "    - Set MaxParallel (affects download concurrency)."
    Write-Host "    - Toggle VerboseMode (adds DEBUG logs; may slow console)."
    Write-Host ""
    Write-Host " 4) View Log (opens current log in Notepad)"
    Write-Host "    - Useful for quick triage."
    Write-Host ""
    Write-Host " 5) Exit"
    Write-Host ""

    $choice = Read-Host "Enter choice (1-5)"
    switch ($choice) {
        '1' { Run-Pipeline }
        '2' { Run-Pipeline -CleanFirst }
        '3' {
            $mp = Read-Host "Enter MaxParallel (current $Global:MaxParallel)"
            if ($mp -match '^\d+$' -and [int]$mp -ge 1 -and [int]$mp -le 64) {
                $Global:MaxParallel = [int]$mp
                Write-Log "[Config] MaxParallel set to $Global:MaxParallel" 'INFO'
            }
            else {
                Write-Log "[Config] Invalid MaxParallel: $mp. Keeping $Global:MaxParallel" 'WARN'
            }

            $toggle = Read-Host "Toggle VerboseMode? (y/n; current: $Global:VerboseMode)"
            if ($toggle.ToLower() -eq 'y') {
                $Global:VerboseMode = -not $Global:VerboseMode
                Write-Log "[Config] VerboseMode toggled to $Global:VerboseMode" 'INFO'
            }
            Show-Menu
        }
        '4' {
            if (Test-Path $LogFile) {
                Start-Process notepad.exe $LogFile
            } else {
                Write-Log "[Menu] No log file found yet." 'WARN'
            }
            Show-Menu
        }
        '5' { Write-Log "[Menu] Exit selected" 'INFO' }
        default {
            Write-Log "[Menu] Invalid choice: $choice" 'WARN'
            Show-Menu
        }
    }
}

Write-Log "Script version 1.2.0 starting. ProjectRoot=$ProjectRoot" 'INFO'

if ($NonInteractive) {
    Write-Log "[Mode] NonInteractive run selected" 'INFO'
    Run-Pipeline -CleanFirst:$CleanFirst
}
else {
    Show-Menu
}

