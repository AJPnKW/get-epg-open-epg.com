[CmdletBinding()]
param(
    [string]$ExcludeFile = "configs/exclude_channels.txt"
)

$ProjectRoot = "C:\Users\Lenovo\PROJECTS\get-epg-open-epg.com\get-epg-open-epg.com"
$OutputDir   = Join-Path $ProjectRoot "data\output"
$LogsDir     = Join-Path $ProjectRoot "logs"
$LogFile     = Join-Path $LogsDir "open-epg.log.txt"

$null = New-Item -ItemType Directory -Force -Path $OutputDir, $LogsDir

function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# Load exclusions
$Exclusions = @()
if (Test-Path $ExcludeFile) {
    $Exclusions = Get-Content $ExcludeFile | Where-Object { $_ -and $_ -notmatch '^\s*$' }
    Write-Log "Loaded exclusions: $($Exclusions.Count)" 'INFO'
}

# Country sources
$CountrySources = @{
    "AU" = @(
        "https://www.open-epg.com/files/australia1.xml.gz",
        "https://www.open-epg.com/files/australia2.xml.gz",
        "https://www.open-epg.com/files/australia3.xml.gz",
        "https://www.open-epg.com/files/australia4.xml.gz"
    )
    "CA" = @(
        "https://www.open-epg.com/files/canada1.xml.gz",
        "https://www.open-epg.com/files/canada2.xml.gz",
        "https://www.open-epg.com/files/canada3.xml.gz",
        "https://www.open-epg.com/files/canada4.xml.gz",
        "https://www.open-epg.com/files/canada5.xml.gz",
        "https://www.open-epg.com/files/canada6.xml.gz"
    )
    "US" = @(
        "https://www.open-epg.com/files/unitedstates1.xml.gz",
        "https://www.open-epg.com/files/unitedstates2.xml.gz",
        "https://www.open-epg.com/files/unitedstates3.xml.gz",
        "https://www.open-epg.com/files/unitedstates4.xml.gz",
        "https://www.open-epg.com/files/unitedstates5.xml.gz",
        "https://www.open-epg.com/files/unitedstates6.xml.gz",
        "https://www.open-epg.com/files/unitedstates7.xml.gz",
        "https://www.open-epg.com/files/unitedstates8.xml.gz",
        "https://www.open-epg.com/files/unitedstates9.xml.gz"
    )
    "UK" = @(
        "https://www.open-epg.com/files/unitedkingdom1.xml.gz",
        "https://www.open-epg.com/files/unitedkingdom2.xml.gz",
        "https://www.open-epg.com/files/unitedkingdom3.xml.gz",
        "https://www.open-epg.com/files/unitedkingdom4.xml.gz",
        "https://www.open-epg.com/files/unitedkingdom5.xml.gz"
    )
}

function Get-CountryEPG {
    param([string]$Country,[string[]]$Urls)

    $mergedDoc = New-Object System.Xml.XmlDocument
    $decl = $mergedDoc.CreateXmlDeclaration("1.0","UTF-8",$null)
    $mergedDoc.AppendChild($decl) | Out-Null
    $tv = $mergedDoc.CreateElement("tv")
    $mergedDoc.AppendChild($tv) | Out-Null

    foreach ($url in $Urls) {
        try {
            Write-Log "Downloading $url" 'INFO'
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $bytes = $resp.Content
            # decompress if gz
            if ($url.EndsWith(".gz")) {
                $ms = New-Object System.IO.MemoryStream
                $ms.Write($bytes,0,$bytes.Length)
                $ms.Seek(0,0) | Out-Null
                $gzip = New-Object System.IO.Compression.GzipStream($ms,[IO.Compression.CompressionMode]::Decompress)
                $sr = New-Object System.IO.StreamReader($gzip)
                $xmlContent = $sr.ReadToEnd()
                $sr.Close(); $gzip.Close(); $ms.Close()
            } else {
                $xmlContent = [System.Text.Encoding]::UTF8.GetString($bytes)
            }

            [xml]$doc = $xmlContent

            foreach ($ch in $doc.tv.channel) {
                if ($Exclusions -and $Exclusions -contains $ch.id) { continue }
                $imported = $mergedDoc.ImportNode($ch,$true)
                $tv.AppendChild($imported) | Out-Null
            }
            foreach ($pg in $doc.tv.programme) {
                if ($Exclusions -and $Exclusions -contains $pg.channel) { continue }
                $imported = $mergedDoc.ImportNode($pg,$true)
                $tv.AppendChild($imported) | Out-Null
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Log "Failed $url : $errMsg" 'ERROR'
        }
    }

    $outFile = Join-Path $OutputDir ("open-epg-{0}.xml" -f $Country.ToLower())
    $mergedDoc.Save($outFile)
    Write-Log "Saved $outFile" 'INFO'
}

foreach ($country in $CountrySources.Keys) {
    Get-CountryEPG -Country $country -Urls $CountrySources[$country]
}
