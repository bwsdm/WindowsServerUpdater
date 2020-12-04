$creds = Get-Credential
[string[]]$servers = Get-Content .\testservers.txt

#foreach($server in $servers) {
$servers | ForEach-Object -Parallel {
  $session = New-PSSession -ComputerName $_ -Credential $using:creds
  $outcome = Invoke-Command -Session $session {
    Import-Module PSWindowsUpdate
    Get-WUHistory -MaxDate (Get-Date).AddDays(-45) | Where { `
      $_.Title -notlike "Security Intelligence*"}
#    Get-WUList -WindowsUpdate -NotCategory "Feature Packs","Tool","Driver"  
  }
  Remove-PSSession $session
  return $outcome
}

