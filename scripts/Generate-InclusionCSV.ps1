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

# --- Collect channel data with progress ---
$channelData = @()
$epgFiles = Get-ChildItem $OutputDir -Filter "open-epg-*.xml" -ErrorAction SilentlyContinue
$epgCount = $epgFiles.Count
$index = 0

foreach ($epg in $epgFiles) {
    $index++
    Write-Progress -Activity "Processing EPG files" `
                   -Status ("File $index of " + $epgCount + ": " + $epg.Name) `
                   -PercentComplete (($index / $epgCount) * 100)

    try {
        [xml]$doc = Get-Content $epg.FullName
        foreach ($chan in $doc.tv.channel) {
            $chanID   = $chan.id
            # Correct way to access <display-name> element(s)
            $chanName = $chan.'display-name'[0]
            # Pre-count programmes for this channel
            $progCount = ($doc.tv.programme | Where-Object { $_.channel -eq $chanID }).Count
            $isExcluded = ($chanID.Trim().ToLower() -in $excludedChannels)

            $channelData += [pscustomobject]@{
                File           = $epg.Name
                ChannelID      = $chanID
                DisplayName    = $chanName
                ProgrammeCount = $progCount
                Excluded       = $isExcluded
            }
        }
    } catch {
        Write-Host "Error parsing $($epg.Name): $($_.Exception.Message)"
    }
}

# --- Save to CSV ---
$csvFile = Join-Path $ConfigDir "include_channels_wip.csv"
$channelData | Sort-Object File, ChannelID | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8

Write-Host "WIP inclusion CSV generated at $csvFile with $($channelData.Count) rows."
