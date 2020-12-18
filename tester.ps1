$creds = Get-Credential MBS\wisdomadmin
[string[]]$servers = Get-Content $args[0]

#foreach($server in $servers) {
$servers | ForEach-Object -Parallel {
  $session = New-PSSession -ComputerName $_ -Credential $using:creds `
    -ErrorVariable err
  $outcome = Invoke-Command -Session $session -ErrorVariable err2 {
    Import-Module PSWindowsUpdate
#    Get-WUHistory -MaxDate (Get-Date).AddDays(-45) | Where { `
#      $_.Title -notlike "Security Intelligence*"}
    Get-WUList -WindowsUpdate -NotCategory "Feature Packs","Tool","Driver"
  }
  Remove-PSSession $session
  if ($err -or $err2) {
    return "$_ is likely rebooting"
  }
  if ($outcome) {
    return $outcome
  }
  else {
    return "$_ has no more updates"
  }
} | Format-Table

