Import-Module PSWindowsUpdate

$creds = Get-Credential MBS\wisdomadmin
[string[]]$servers = Get-Content $args[0]
$startTime = Get-Date
$date = Get-Date -Format "MMddyyyy"

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
  # Look into importing the module on failure.
  # There looked to be an easy way to do this.
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


function Get-Updates([String]$s, $c) {

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
  Invoke-WUJob -ComputerName $s -RunNow -Confirm:$false -Script {
    Import-Module PSWindowsUpdate 
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll `
      -NotCategory 'Feature Packs','Tool','Driver' -AutoReboot | `
      Out-File C:\mbs-bin\updatelog.log
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
  $results = @{}
  # Check each server's status
  $results = $goodServers | ForEach-Object -Parallel {
    $session = New-PSSession -ComputerName $_ -Credential $using:creds `
      -ErrorVariable err
    $outcome = Invoke-Command -Session $session -ErrorVariable err2 {
      Import-Module PSWindowsUpdate
      Get-WUList -MicrosoftUpdate -NotCategory "Feature Packs", "Tool", "Driver"
    }
    Remove-PSSession $session
    if ($err -or $err2) {
      Write-Output "$_ Rebooting"
      return "$_ Rebooting" 
    }
    if ($outcome) {
      Write-Output "$_ Running"
      return "$_ Running"
    }
    else {
      Write-Output "$_ Done"
      return "$_ Done"
    }
  }

  foreach($result in $results) {
    $result = $result.Split(" ")
    $runningTable[$result[0]] = $result[1]
  }
  
  # Checks for new updates on servers that are done
  # If they are done, we mark them finished
  foreach($server in $goodServers) {
    if($runningTable[$server] -eq "Done") {
      $remainingUpdates = Get-Updates($server,$c)
      if(!$remainingUpdates) {
        Start-Updates($server)
        $runningTable[$server] = "Updating"
      }
      else {
        $runningTable[$server] = "Finished"
      }
    }
  }
  
  Write-Output $runningTable
  
  $finished = $true
  foreach ($server in $goodServers) {
    if($runningTable[$server] -ne "Finished") {
      $finished = $false
      break
    }
  }

  if($finished) {
    Write-Output "We are done!"
    break
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
