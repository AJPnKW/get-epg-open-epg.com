param(
    [string]$InputDir = "..\data\output",
    [string]$OutputFile = "..\data\output\channels.csv"
)

$null = New-Item -ItemType Directory -Force -Path (Split-Path $OutputFile)

# Network list (keyword match)
$Networks = @(
    "A+E Networks","ABC","ABC - AU","BBC","CBC","CBS","Citytv","Crave","CTV","CTV 2","CW",
    "Food Network","FOX","Global","HBO","ION","ITV","NBC","Network","Network 10","OMNI",
    "PBS","Pluto TV","SBS","The CW","TVOntario","Warner","Discovery"
)

# Type keywords (keyword match)
$Types = @("business","comedy","cooking","culture","documentary","entertainment",
           "general","lifestyle","movies","music","news","science","series")

$rows = @()
foreach ($file in Get-ChildItem $InputDir -Filter "open-epg-*.xml") {
    $country = ($file.BaseName -replace 'open-epg-','').ToUpper()
    [xml]$doc = Get-Content $file.FullName
    foreach ($ch in $doc.tv.channel) {
        $name = ($ch."display-name" | ForEach-Object { $_.'#text' }) -join ';'
        $network = "Unknown"
        $type    = "Unknown"

        foreach ($n in $Networks) { if ($name -like "*$n*") { $network = $n; break } }
        foreach ($t in $Types)    { if ($name -like "*$t*") { $type    = $t; break } }

        $rows += [pscustomobject]@{
            Country   = $country
            ChannelID = $ch.id
            Name      = $name
            Network   = $network
            Type      = $type
        }
    }
}

$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Channel list saved to $OutputFile"
