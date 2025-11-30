<#
.SYNOPSIS
  Fetches multiple XMLTV EPG feeds from open-epg.com, preferring .xml.gz with
  smart fallback to .xml, logs all activity with timestamps, and merges into
  a single deduplicated XMLTV file: open-epg.xml.

.DESCRIPTION
  - Multithreaded downloads (PowerShell 7+ ForEach-Object -Parallel).
  - Visible progress indicators (console progress + spinner).
  - Timestamped logging to logs\open-epg.log.txt.
  - Continues on individual source errors and records them.
  - Falls back from .xml.gz to .xml automatically.
  - Merges channels and programmes, deduplicates by:
      channel @id; programme (channel, start, stop, title).
  - QA checks: root structure, counts, duplicates, missing ids.
  - Defensive file handling and clean temp workspace.

.PARAMETER MaxParallel
  Maximum parallel download workers (default: 8).

.PARAMETER ForceClean
  If specified, cleans working download folder before run.

.NOTES
  Version: 1.0.0
  Author: Andrew (AJPnKW); script designed with robust logging and resilience.
  Requires: PowerShell 7+, .NET XML support.
#>

[CmdletBinding()]
param(
    [int]$MaxParallel = 8,
    [switch]$ForceClean
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

$ProgressId  = 1

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
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

# Console spinner for visual indicator of activity
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
# Note: Some links include double slashes; we normalize them.
# ----------------------------
$Sources = @(
    @{ Name='Australia 1'; Gz='https://www.open-epg.com/files/australia1.xml.gz'; Xml='https://www.open-epg.com/files/australia1.xml' },
    @{ Name='Australia 2'; Gz='https://www.open-epg.com/files/australia2.xml.gz'; Xml='https://www.open-epg.com/files/australia2.xml' },
    @{ Name='Australia 3'; Gz='https://www.open-epg.com/files/australia3.xml.gz'; Xml='https://www.open-epg.com/files/australia3.xml' },
    @{ Name='Australia 4'; Gz='https://www.open-epg.com/files/australia4.xml.gz'; Xml='https://www.open-epg.com/files/australia4.xml' },

    @{ Name='Canada 1';   Gz='https://www.open-epg.com/files/canada1.xml.gz';    Xml='https://www.open-epg.com/files/canada1.xml' }, # fixed likely index
    @{ Name='Canada 2';   Gz='https://www.open-epg.com/files/canada2.xml.gz';    Xml='https://www.open-epg.com/files/canada2.xml' },
    @{ Name='Canada 3';   Gz='https://www.open-epg.com/files/canada3.xml.gz';    Xml='https://www.open-epg.com/files/canada3.xml' },
    @{ Name='Canada 4';   Gz='https://www.open-epg.com/files/canada4.xml.gz';    Xml='https://www.open-epg.com/files/canada4.xml' },
    @{ Name='Canada 5';   Gz='https://www.open-epg.com/files/canada5.xml.gz';    Xml='https://www.open-epg.com/files/canada5.xml' },
    @{ Name='Canada 6';   Gz='https://www.open-epg.com/files/canada6.xml.gz';    Xml='https://www.open-epg.com/files/canada6.xml' },

    @{ Name='United States 1'; Gz='https://www.open-epg.com/files/unitedstates1.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates1.xml' },
    @{ Name='United States 2'; Gz='https://www.open-epg.com/files/unitedstates2.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates2.xml' },
    @{ Name='United States 3'; Gz='https://www.open-epg.com/files/unitedstates3.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates3.xml' },
    @{ Name='United States 4'; Gz='https://www.open-epg.com/files/unitedstates4.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates4.xml' },
    @{ Name='United States 5'; Gz='https://www.open-epg.com/files/unitedstates5.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates5.xml' },
    @{ Name='United States 6'; Gz='https://www.open-epg.com/files/unitedstates6.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates6.xml' },
    @{ Name='United States 7'; Gz='https://www.open-epg.com/files/unitedstates7.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates7.xml' },
    @{ Name='United States 8'; Gz='https://www.open-epg.com/files/unitedstates8.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates8.xml' },
    @{ Name='United States 9'; Gz='https://www.open-epg.com/files/unitedstates9.xml.gz'; Xml='https://www.open-epg.com/files/unitedstates9.xml' },

    @{ Name='United Kingdom 1'; Gz='https://www.open-epg.com/files/unitedkingdom1.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom1.xml' },
    @{ Name='United Kingdom 2'; Gz='https://www.open-epg.com/files/unitedkingdom2.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom2.xml' },
    @{ Name='United Kingdom 3'; Gz='https://www.open-epg.com/files/unitedkingdom3.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom3.xml' },
    @{ Name='United Kingdom 4'; Gz='https://www.open-epg.com/files/unitedkingdom4.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom4.xml' },
    @{ Name='United Kingdom 5'; Gz='https://www.open-epg.com/files/unitedkingdom5.xml.gz'; Xml='https://www.open-epg.com/files/unitedkingdom5.xml' }
)

# ----------------------------
# Utility: Normalize URL (fix accidental double slashes in path)
# ----------------------------
function Normalize-Url {
    param([string]$Url)
    # Preserve protocol double slash; collapse redundant slashes after host.
    if ($Url -match '^(https?://)(.+)$') {
        $proto = $matches[1]; $rest = $matches[2]
        $rest = $rest -replace '//+', '/'
        return "$proto$rest"
    }
    return $Url
}

# ----------------------------
# Download with fallback (.gz -> .xml)
# ----------------------------
function Download-EpgSource {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$GzUrl,
        [Parameter(Mandatory)] [string]$XmlUrl,
        [Parameter(Mandatory)] [string]$OutDir
    )

    $result = [ordered]@{
        Name        = $Name
        SourceUrl   = $null
        OutputFile  = $null
        Status      = 'Unknown'
        Bytes       = 0
        Error       = $null
    }

    try {
        $gzUrl  = Normalize-Url $GzUrl
        $xmlUrl = Normalize-Url $XmlUrl

        $targetGz  = Join-Path $OutDir ("{0}.xml.gz" -f ($Name -replace '\s+', '_').ToLower())
        $targetXml = Join-Path $OutDir ("{0}.xml"    -f ($Name -replace '\s+', '_').ToLower())

        # Attempt .gz first
        Write-Log "[$Name] Trying .gz: $gzUrl" 'INFO'
        try {
            Invoke-WebRequest -Uri $gzUrl -OutFile $targetGz -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $result.SourceUrl  = $gzUrl
            $result.OutputFile = $targetGz
            $result.Status     = 'DownloadedGz'
            $result.Bytes      = (Get-Item $targetGz).Length
            Write-Log "[$Name] Downloaded GZ ($($result.Bytes) bytes)" 'INFO'
        }
        catch {
            Write-Log "[$Name] .gz failed: $($_.Exception.Message). Falling back to .xml: $xmlUrl" 'WARN'
            Invoke-WebRequest -Uri $xmlUrl -OutFile $targetXml -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            $result.SourceUrl  = $xmlUrl
            $result.OutputFile = $targetXml
            $result.Status     = 'DownloadedXml'
            $result.Bytes      = (Get-Item $targetXml).Length
            Write-Log "[$Name] Downloaded XML ($($result.Bytes) bytes)" 'INFO'
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Error  = $_.Exception.Message
        Write-Log "[$Name] Download failed: $($result.Error)" 'ERROR'
    }

    return $result
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
            # Use System.IO.Compression.GzipStream
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
# Merge XMLTV documents into single file
# Dedup keys:
#   - channel: @id
#   - programme: (channel/@id, @start, @stop, title text)
# ----------------------------
function Merge-XmlTv {
    param(
        [Parameter(Mandatory)][string[]]$XmlFiles,
        [Parameter(Mandatory)][string]$OutputFile
    )

    Write-Log "[Merge] Starting merge of $($XmlFiles.Count) files" 'INFO'

    # Create root <tv> with metadata
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

    foreach ($file in $XmlFiles) {
        if (-not (Test-Path $file)) {
            Write-Log "[Merge] Missing file: $file" 'WARN'
            continue
        }

        try {
            Write-Log "[Merge] Parsing: $file" 'INFO'
            [xml]$doc = Get-Content -Path $file -Raw
            if ($null -eq $doc.tv) {
                Write-Log "[Merge] Invalid XMLTV structure (no <tv>): $file" 'WARN'
                continue
            }

            # Merge channels
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
                }
                else {
                    $dupChannels++
                }
            }

            # Merge programmes
            foreach ($pg in $doc.tv.programme) {
                $chid  = $pg.channel
                $start = $pg.start
                $stop  = $pg.stop
                $title = $pg.title -join '' # handle localized title nodes

                $key = "{0}|{1}|{2}|{3}" -f $chid, $start, $stop, ($title ?? '').Trim()
                if ($programmeKeys.Add($key)) {
                    $imported = $rootDoc.ImportNode($pg, $true)
                    $tv.AppendChild($imported) | Out-Null
                    $totalProgrammes++
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

    # Write output
    try {
        Write-Log "[Merge] Writing output: $OutputFile" 'INFO'
        $rootDoc.Save($OutputFile)
        Write-Log "[Merge] Complete: Channels=$totalChannels (+$dupChannels dup), Programmes=$totalProgrammes (+$dupProgrammes dup)" 'INFO'
    }
    catch {
        Write-Log "[Merge] Failed to write output: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

# ----------------------------
# QA checks
# ----------------------------
function Validate-XmlTv {
    param([Parameter(Mandatory)][string]$XmlPath)
    $issues = @()

    try {
        [xml]$doc = Get-Content -Path $XmlPath -Raw
        if ($null -eq $doc.tv) { $issues += "Missing <tv> root" }

        $channelCount = ($doc.tv.channel | Measure-Object).Count
        $programmeCount = ($doc.tv.programme | Measure-Object).Count
        if ($channelCount -eq 0) { $issues += "No channels found" }
        if ($programmeCount -eq 0) { $issues += "No programmes found" }

        Write-Log "[QA] Channels=$channelCount; Programmes=$programmeCount" 'INFO'
    }
    catch {
        $issues += "Cannot parse XML: $($_.Exception.Message)"
    }

    if ($issues.Count -gt 0) {
        foreach ($i in $issues) { Write-Log "[QA] Issue: $i" 'WARN' }
    }
    else {
        Write-Log "[QA] Validation passed" 'INFO'
    }
}

# ----------------------------
# Main flow
# ----------------------------
Write-Log "===== START Open-EPG Merge Run =====" 'INFO'

try {
    if ($ForceClean) {
        Write-Log "[Init] Cleaning downloads/work directories" 'INFO'
        Get-ChildItem -Path $Downloads -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $WorkDir   -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Parallel downloads
    Write-Log "[Init] Starting downloads (max parallel: $MaxParallel)" 'INFO'
    $downloadResults = $Sources | ForEach-Object -Parallel {
        param($Downloads)
        # Re-create minimal helpers in parallel runspace
        function Normalize-Url {
            param([string]$Url)
            if ($Url -match '^(https?://)(.+)$') {
                $proto = $matches[1]; $rest = $matches[2]
                $rest = $rest -replace '//+', '/'
                return "$proto$rest"
            }
            return $Url
        }
        try {
            $name   = $_.Name
            $gzUrl  = $_.Gz
            $xmlUrl = $_.Xml

            $gzUrl  = Normalize-Url $gzUrl
            $xmlUrl = Normalize-Url $xmlUrl

            $safeName = ($name -replace '\s+', '_').ToLower()
            $targetGz  = Join-Path $Downloads ("{0}.xml.gz" -f $safeName)
            $targetXml = Join-Path $Downloads ("{0}.xml"    -f $safeName)

            $result = [ordered]@{
                Name        = $name
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

            # lightweight progress marker
            $result
        }
        } -ArgumentList $Downloads -ThrottleLimit $MaxParallel

    # Log outcomes
    foreach ($dr in $downloadResults) {
        switch ($dr.Status) {
            'DownloadedGz'  { Write-Log "[$($dr.Name)] OK .gz ($($dr.Bytes) bytes): $($dr.SourceUrl)" 'INFO' }
            'DownloadedXml' { Write-Log "[$($dr.Name)] OK .xml ($($dr.Bytes) bytes): $($dr.SourceUrl)" 'INFO' }
            'Failed'        { Write-Log "[$($dr.Name)] FAILED: $($dr.Error)" 'ERROR' }
            default         { Write-Log "[$($dr.Name)] Unknown status" 'WARN' }
        }
        Show-Spinner -Activity "Downloading"
    }

    # Decompress where needed
    Write-Log "[Init] Decompressing gz files (if any)" 'INFO'
    $toProcess = @()
    foreach ($dr in $downloadResults) {
        if ($dr.Status -in @('DownloadedGz','DownloadedXml')) {
            $info = Expand-GzipIfNeeded -InputPath $dr.OutputFile -OutputDir $WorkDir
            if ($info.Status -in @('Decompressed','AlreadyXml')) {
                $toProcess += $info.OutputXml
            }
        }
        else {
            Write-Log "[Init] Skipping due to previous failure: $($dr.Name)" 'WARN'
        }
    }

    # Merge
    if ($toProcess.Count -gt 0) {
        Merge-XmlTv -XmlFiles $toProcess -OutputFile $OutputFile
        Validate-XmlTv -XmlPath $OutputFile
        Write-Log "[Done] Output saved: $OutputFile" 'INFO'
        Write-Host ""
        Write-Host "========================================================="
        Write-Host "Open EPG merge complete."
        Write-Host "Output: $OutputFile"
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
