Import-Module PSWindowsUpdate

$creds = Get-Credential
[string[]]$servers = Get-Content $args[0]
$startTime = Get-Date
$date = Get-Date -Format "MM/dd/yyyy"

#$goodServers = @()
$runningTable = @{}

if(!(Test-Path C:\mbs-bin\WSULogs)) {
  Write-Host "Directory C:\mbs-bin\WSULogs created"
  New-Item -Path "C:\mbs-bin\WSULogs\" -Force -ItemType Directory
}

function TestModules {
  Param(
    $s,
    $c
  )

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
  Get-PSSession | Remove-PSSession   
  return $outcome
}


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


function Start-Updates($s) {
  Write-Output "Invoke Server: $($s)"
  Invoke-WUJob -ComputerName $s -Script {
    Import-Module PSWindowsUpdate
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll `
      -NotCatergory 'Feature Packs','Tool','Driver' | `
      Out-File C:\mbs-bin\updatelog.log | `
      Restart-Computer # This may not be needed. Want to make sure file is written
  } -RunNow -confirm:$false
}    

function GetUpdateStatus {
  Param(
    $s,
    $c
  )

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

<#
  Ok so this is awful. Parallel foreach is similar to running individual runspaces.
  At this time there is no easy way to pass in functions to those runspaces.
  As a result you have to create a string copy of the function definition
  and then pass it into the runspace using $using and the convert the string
  back to a function.

  Also, $function doesn't like the "-" in the Verb-Noun naming convention so I had
  to change those to other names.
#>

$tmDef = $function:TestModules.ToString()
[string[]]$goodServers = $servers | ForEach-Object -Parallel {
  $function:TestModules = $using:tmDef
  $testOutcome = TestModules $_ $using:creds
  if($testOutcome) {
    return $_
  }
}

Write-Output "Good Servers: $($goodServers)"

foreach($server in $goodServers) {
  $s = "$($server).mbs.tamu.edu"
  Write-Output "Server Name: $($s)"
  Start-Updates($s)
}


# Need to look at good servers that dont start updates for whatever reason
Do {

  # Check each server's status
  $gusDef = $function:GetUpdateStatus.ToString()
  [string[]]$results = $goodServers | ForEach-Object -Parallel {
    $function:GetUpdateStatus = $using:gusDef
    $status = GetUpdateStatus $_ $using:creds
    $returnArray = @($_, $status)
    return $returnArray
  }

  foreach($result in $results) {
    $runningTable[$result[0]] = $result[1]
  }
  
  # Checks for new updates on servers that are done
  # If they are done, we mark them finished
  foreach($entry in $runningTable.GetEnumerator()) {
    if($entry.Value -eq "Updated") {
      $remainingUpdates = Get-Updates($entry.Key,$c)
      if(!$remainingUpdates) {
        Start-Updates($entry.Key)
        $runningTable[$entry.Key] = "Updating"
      }
      else {
        $runningTable[$entry.Key] = "Done"
      }
    }
  }
  
  Write-Output $runningTable
  
  $finished = $true
  foreach ($entry in $runningTable.GetEnumerator()) {
    if($entry.Value -ne "Done") {
      $finished = $false
      break
    }
  }

  if($finished) {
    Write-Output "We are done!"
  }
  
  Start-Sleep 120
}
Until ($finished)


# Fetching logs from each server
Write-Output "Fetching update logs from each server"
foreach($server in $goodServers) {
  Copy-Item "\\$($server).mbs.tamu.edu\C$\mbs-bin\updatelog.log" `
    -Destination "C:\mbs-bin\WSULogs\$($date)$($server)updatelog.log"
}

Write-Output "Fetch complete. See logs at C:\mbs-bin\WSULogs"
