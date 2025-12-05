[CmdletBinding()]
param(
    [string]$ProjectRoot = "C:\Users\Lenovo\PROJECTS\get-epg-open-epg.com\get-epg-open-epg.com"
)

# --- Paths ---
$OutputDir = Join-Path $ProjectRoot "scripts\data\output"
$ConfigDir = Join-Path $ProjectRoot "configs"

# --- Load exclusion file ---
$excludeFile = Join-Path $ConfigDir "exclude_channels.txt"
$excludedChannels = @()
if (Test-Path $excludeFile) {
    $excludedChannels = Get-Content $excludeFile |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim().ToLower() }
    Write-Host "Loaded $($excludedChannels.Count) exclusions."
} else {
    Write-Host "Exclusion file not found at $excludeFile"
}

# --- Gather EPG files ---
$epgFiles = Get-ChildItem $OutputDir -Filter "open-epg-*.xml" -ErrorAction SilentlyContinue
$epgCount = $epgFiles.Count
Write-Host "Found $epgCount EPG files to process."

# --- Process files in parallel ---
$channelData = $epgFiles | ForEach-Object -Parallel {
    try {
        # Load XML
        [xml]$doc = Get-Content $_.FullName

        # Build programme lookup table once
        $progLookup = $doc.tv.programme | Group-Object channel -AsHashTable

        $results = @()
        foreach ($chan in $doc.tv.channel) {
            $chanID   = $chan.id
            $chanName = $chan.'display-name'[0]

            # Fast lookup for programme count
            $progCount = if ($progLookup.ContainsKey($chanID)) { $progLookup[$chanID].Count } else { 0 }

            # Exclusion check
            $isExcluded = ($chanID.Trim().ToLower() -in $using:excludedChannels)

            $results += [pscustomobject]@{
                File           = $_.Name
                ChannelID      = $chanID
                DisplayName    = $chanName
                ProgrammeCount = $progCount
                Excluded       = $isExcluded
            }
        }
        $results
    } catch {
        Write-Host "Error parsing $($_.Name): $($_.Exception.Message)"
    }
} -ThrottleLimit 4   # adjust threads based on CPU cores

# --- Save to CSV ---
$csvFile = Join-Path $ConfigDir "include_channels_wip.csv"
$channelData | Sort-Object File, ChannelID | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

Write-Host "WIP inclusion CSV generated at $csvFile with $($channelData.Count) rows."
