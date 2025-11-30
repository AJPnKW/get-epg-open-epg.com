param(
    [string]$InputDir = "data\output",
    [string]$OutputFile = "data\output\channels.csv"
)

$rows = @()
foreach ($file in Get-ChildItem $InputDir -Filter "open-epg-*.xml") {
    $country = ($file.BaseName -replace 'open-epg-','').ToUpper()
    [xml]$doc = Get-Content $file.FullName
    foreach ($ch in $doc.tv.channel) {
        $rows += [pscustomobject]@{
            Country = $country
            ChannelID = $ch.id
            Name = ($ch.display-name | ForEach-Object { $_.'#text' }) -join ';'
        }
    }
}
$rows | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
Write-Host "Channel list saved to $OutputFile"
