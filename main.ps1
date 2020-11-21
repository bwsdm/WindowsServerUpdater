$creds = Get-Credential
$servers = Get-Content .\testservers.txt
$startTime = Get-Date
$date = Get-Date -Format "MM/dd/yyyy"

$updatesList = @()
$goodServers = @()
$runningTable = @{}
New-Item -Path "C:\mbs-bin\WSULogs"


function Test-Modules($s, $c) {
  $session = New-PSSession -ComputerName $s -Credential $c -ErrorAction SilentlyContinue
  $outcome = Invoke-Command -Session $session {
    Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue -ErrorVariable err
    if($err) {
      return $false
    }
    else {
      return $true
    }
  }
  
  return $outcome
}


# Is this even needed?
function Get-Updates($s, $c) {
  if(Test-Connection $s -Quiet -Count 2) {

      $session = New-PSSession -ComputerName $s -Credential $c -ErrorAction Stop
      $updates = Invoke-Command -Session $session {
          Import-Module PSWindowsUpdate
          $updates = Get-WindowsUpdate -WindowsUpdate
          return $updates.Title

      }
      Get-PSSession | Remove-PSSession
      $updatesObject = New-Object -TypeName PSObject -Property @{
          Server = $s
          Updates = $updates
      }

      return $updatesObject
  }
  else {
      $updatesObject = New-Object -TypeName PSObject -Property @{
          Server = $s
          Updates = "We couldnt fetch updates due to a connection error"
      }

      return $updatesObject
  }
}


function Start-Updates($serverList) {
  Invoke-WUJob -ComputerName $serverList -Script {
    Import-Module PSWindowsUpdate
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll `
      -NotCatergory 'Feature Packs','Tool','Driver' | `
      Out-File C:\mbs-bin\updatelog.log | `
      Restart-Computer # This may not be needed. Want to make sure file is written
  } -RunNow -confirm:$false
}    

function Get-UpdateStatus($s, $c) {
  $session = New-PSSession -ComputerName $s -Credential $c -ErrorAction SilentlyContinue `
    -ErrorVariable err
  $isBusy = Invoke-Command -Session $session {
    Import-Module PSWindowsUpdate
    $status = Get-WuInstallerStatus
    return $status.IsBusy
  }
  if((-not $err) -and ($isBusy)) {
    return "Updating"
  }
  elseif((-not $err) -and (-not $isBusy)) {
    return "Updated"
  }
  else {
    return "Restarting"
  }
}

# Main Loop
# Maybe look into a way to fix servers that dont have module
foreach($server in $servers) {
  # Make this a job for parallel testing
  $testOutcome = Test-Modules($server,$creds)
  if($testOutcome) {
    $goodServers += $server
  }
}

# Make this a job for parallel processing
Start-Updates($goodServers)



# Need to look at good servers that dont start updates for whatever reason
Do {

  # Check each server's status
  foreach($server in $goodServers) {
    $status = Get-UpdateStatus($server,$creds)
    $runningTable[$server] = $status
  }
  
  # Checks for new updates on servers that are done
  # If they are done, we mark them finished
  foreach($entry in $runningTable.GetEnumerator()) {
    if($entry.Value -eq "Updated") {
      $remainingUpdates = Get-Updates($entry.Key,$c)
      if(!$remainingUpdates) {
        Start-Updates($entry.Key)
        $runningTable[$entry.Key] = "Updating"
      else {
        $runningTable[$entry.Key] = "Done"
      }
    }
  }
  
  Write-Host $runningTable
  
  $finished = $true
  foreach ($entry in $runningTable.GetEnumerator()) {
    if($entry.Value -ne "Done") {
      $finished = $false
      break
    }
  }

  if($finished) {
    Write-Host "We are done!"
  }

}
Until ($finished)


# Fetching logs from each server
Write-Host "Fetching update logs from each server"
foreach($server in $goodServers) {
  Copy-Item "\\$($server).mbs.tamu.edu\C$\mbs-bin\updatelog.log" `
    -Destination "C:\mbs-bin\WSULogs\$($date)$($server)updatelog.log"
}

Write-Host "Fetch complete. See logs at C:\mbs-bin\WSULogs"
