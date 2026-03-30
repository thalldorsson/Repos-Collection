$mds = Get-ChildItem -Path (Join-Path $PSScriptRoot '.') -Recurse -Filter *.md
$dupReport = @()
foreach($f in $mds){
  $heads = Select-String -Path $f.FullName -Pattern '^#{1,6} ' | ForEach-Object { $_.Line.Trim() }
  $dups = $heads | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [PSCustomObject]@{ File=$f.FullName; Heading=$_.Name; Count=$_.Count } }
  if($dups){ $dupReport += $dups }
}
if($dupReport){ $dupReport | Sort-Object File,Heading | Format-Table -AutoSize } else { Write-Output 'No duplicate headings (exact text) detected across individual files.' }
