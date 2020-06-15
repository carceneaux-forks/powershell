<#
.SYNOPSIS
	Veeam Agent-based backup reporting script

.DESCRIPTION
	This script will allows you to pull all agent-based backup
    information accessible on the VBR server and generate a report from it.

.OUTPUTS
	HTML report

.EXAMPLE
	.\New-Veeam-Agent-Backups-Report.ps1

	Description
	-----------
	Run script from (an elevated) PowerShell console

.NOTES
	NAME:  New-Veeam-Agent-Backups-Report.ps1
	VERSION: 1.0
	AUTHOR: Chris Arceneaux
	TWITTER: @chris_arceneaux
	GITHUB: https://github.com/carceneaux
    CREDIT: Shawn Masterson - https://www.linkedin.com/in/smmasterson/

    Testing environment: Veeam Backup & Replication 10

.LINK
	https://arsano.ninja/

.LINK
	https://helpcenter.veeam.com/docs/backup/powershell/veeam_agent_management.html?ver=100
#>

##### USER VARIABLES BELOW :: PLEASE ADJUST FOR YOUR ENVIRONMENT #####

# VBR Server (Server Name, FQDN or IP)
#$vbrServer = "yourVBRserver"
$vbrServer = "veeam.arsano.lab"
# Report Title
$rptTitle = "Veeam Agent-based Backups Report"
# Show VBR Server name in report header
$showVBR = $true
# HTML Report Width (Percent)
$rptWidth = 97
# Save HTML output to a file
$saveHTML = $true
# HTML File output path and filename
$pathHTML = "C:\VeeamAgentReport_$(Get-Date -format MMddyyyy_hhmmss).htm"
# Launch HTML file after creation
$launchHTML = $true

##### USER VARIABLES ABOVE :: DO NOT EDIT CODE BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING #####

# Load Veeam Snapin
If (!(Get-PSSnapin -Name VeeamPSSnapIn -ErrorAction SilentlyContinue)) {
  If (!(Add-PSSnapin -PassThru VeeamPSSnapIn)) {
    Write-Error "Unable to load Veeam snapin" -ForegroundColor Red
    Exit
  }
}

# Connect to VBR server
$OpenConnection = (Get-VBRServerSession).Server
If ($OpenConnection -ne $vbrServer){
  Disconnect-VBRServer
  Try {
    Connect-VBRServer -server $vbrServer -ErrorAction Stop
  } Catch {
    Write-Host "Unable to connect to VBR server - $vbrServer" -ForegroundColor Red
    exit
  }
}

# Toggle VBR Server name in report header
If ($showVBR) {
  $vbrName = "VBR Server - $vbrServer"
} Else {
  $vbrName = $null
}

# Initializing usage variables (used to generate the final report)
$session_info = @()
$file_info = @()
$rp_info = @()

# Gathering Agent-based Backup Jobs with Backup information
$jobs = Get-VBRComputerBackupJob
$sessions = Get-VBRComputerBackupJobSession
$backups = Get-VBRBackup

# Looping through each job
foreach ($job in $jobs){
    # Matching backup with job ID
    $backup = $backups | ?{$_.JobId -eq $job.id}

    # Parsing backup sessions
    $job_sessions = $sessions |?{$_.JobId -eq $job.Id}
    # Identifying days where a backup session took place
    $session_days = $job_sessions | Select-Object @{Name="Month";Expression={$_.CreationTime.Month}}, @{Name="Day";Expression={$_.CreationTime.Day}}, @{Name="Year";Expression={$_.CreationTime.Year}} -Unique
    # Parsing out backup sessions on a daily basis
    foreach ($day in $session_days){
        # Finding all backup sessions that ran on this specific day (job specific)
        $daily_sessions = $job_sessions | ?{($_.CreationTime.Month -eq $day.Month) -and ($_.CreationTime.Day -eq $day.Day) -and ($_.CreationTime.Year -eq $day.Year)}

        # Session-specific metrics
        $successResult = 0
        $warningResult = 0
        $failedResult = 0
        $overtime = $false
        foreach ($session in $daily_sessions){
            if ($session.State -ne "Stopped"){
                $time = New-TimeSpan $daily_sessions[0].CreationTime (Get-Date)
                # Are there sessions still running over 24 hours?
                if ($time.TotalHours -gt 24){
                    $overtime = $true
                }
            }
            switch ($session.Result)
            {
                "Success" {
                    $successResult++
                    break
                }
                "Warning" {
                    $warningResult++
                    break
                }
                "Failed" {
                    $failedResult++
                    break
                }
            }
        }  #end session loop

        # Capturing metrics
        $object = [PSCustomObject] @{
            JobId = $job.id
            CreationTime = Get-Date -Month $day.Month -Day $day.Day -Year $day.Year -Hour 0 -Minute 0 -Second 0
            SessionCount = $daily_sessions.count
            SuccessResult = $successResult
            WarningResult = $warningResult
            FailedResult = $failedResult
            Overtime = $overtime
        }
        $session_info += $object
    }  #end day loop

    # Retrieving all child jobs
    $childJobs = $backup.FindChildBackups()

    # Looping through each child job
    foreach ($childJob in $childJobs){
        # Looping through each file
        $files = $childJob.GetAllStorages()
        foreach ($file in $files | Sort-Object CreationTime -Descending){
            # Checking for GFS
            if ($file.GfsPeriod -eq "None"){ $gfs = $false }
            else { $gfs = $true }

            # Converting sizes to GB
            $BackupSizeGB = [math]::round($file.Stats.BackupSize / 1Gb, 2) #convert from bytes to GB
            $DataSizeGB = [math]::round($file.Stats.DataSize / 1Gb, 2) #convert from bytes to GB

            # Capturing metrics
            $object = [PSCustomObject] @{
                JobId = $job.id
                ChildJobId = $childJob.id
                CreationTime = Get-Date -Month $file.CreationTime.Month -Day $file.CreationTime.Day -Year $file.CreationTime.Year -Hour 0 -Minute 0 -Second 0
                Incremental = $file.IsIncrementalFast
                Full = $file.IsFull
                Gfs = $gfs
                BackupSizeGB = $BackupSizeGB
                DataSizeGB = $DataSizeGB
                DedupRatio = $file.Stats.DedupRatio
                CompressRatio = $file.Stats.CompressRatio
            }
            $file_info += $object
        }  #end file loop

        # Looping through each restore point
        $rps = $childJob.GetPoints()
        foreach ($rp in $rps | Sort-Object CreationTime -Descending){
            # Capturing metrics
            $object = [PSCustomObject] @{
                JobId = $job.id
                ChildJobId = $childJob.id
                RestorePointId = $rp.id
                CreationTime = Get-Date -Month $rp.CreationTime.Month -Day $rp.CreationTime.Day -Year $rp.CreationTime.Year -Hour 0 -Minute 0 -Second 0
                Incremental = $rp.IsIncremental
                Full = $rp.IsFull
            }
            $rp_info += $object
        }  #end restore point loop
    }  #end child jobs loop
}  #end jobs loop

#$file_info
#$session_info
#$rp_info

##### BEGIN REPORT GENERATION #####
# HTML Stuff
$headerObj = @"
<html>
    <head>
        <title>$rptTitle</title>
            <style>
              body {font-family: Tahoma; background-color:#ffffff;}
              table {font-family: Tahoma;width: $($rptWidth)%;font-size: 12px;border-collapse:collapse;}
              <!-- table tr:nth-child(odd) td {background: #e2e2e2;} -->
              th {background-color: #e2e2e2;border: 1px solid #a7a9ac;border-bottom: none;}
              td {background-color: #ffffff;border: 1px solid #a7a9ac;padding: 2px 3px 2px 3px;}
            </style>
    </head>
"@

$bodyTop = @"
    <body>
        <center>
            <table>
                <tr>
                    <td style="width: 50%;height: 14px;border: none;background-color: ZZhdbgZZ;color: White;font-size: 10px;vertical-align: bottom;text-align: left;padding: 2px 0px 0px 5px;"></td>
                    <td style="width: 50%;height: 14px;border: none;background-color: ZZhdbgZZ;color: White;font-size: 12px;vertical-align: bottom;text-align: right;padding: 2px 5px 0px 0px;">Report generated on $(Get-Date -format g)</td>
                </tr>
                <tr>
                    <td style="width: 50%;height: 24px;border: none;background-color: ZZhdbgZZ;color: White;font-size: 24px;vertical-align: bottom;text-align: left;padding: 0px 0px 0px 15px;">$rptTitle</td>
                    <td style="width: 50%;height: 24px;border: none;background-color: ZZhdbgZZ;color: White;font-size: 12px;vertical-align: bottom;text-align: right;padding: 0px 5px 2px 0px;">$vbrName</td>
                </tr>
            </table>
"@

$subHead01 = @"
                    <td style="height: 35px;background-color: #f3f4f4;color: #626365;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead01total = @"
                    <td style="height: 35px;background-color: #ABABAB;color: #ffffff;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead01suc = @"
                    <td style="height: 35px;background-color: #00b050;color: #ffffff;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead01war = @"
                    <td style="height: 35px;background-color: #ffd96c;color: #ffffff;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead01err = @"
                    <td style="height: 35px;background-color: #FB9895;color: #ffffff;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead01mix = @"
                    <td style="height: 35px;background-color: #FFA500;color: #ffffff;font-size: 16px;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;">
"@

$subHead02 = @"
</td>
                </tr>
"@

$HTMLbreak = @"
<table>
                <tr>
                    <td style="height: 10px;background-color: #626365;padding: 5px 0 0 15px;border-top: 5px solid white;border-bottom: none;"></td>
						    </tr>
            </table>
"@

$footerObj = @"
        </center>
    </body>
</html>
"@

# Determining all dates
$dates = $rp_info | %{$_.CreationTime -f 'M/d/yyyy'} | Select -Unique
$dates = $dates | %{Get-Date $_} | %{$_.Tostring("M/d/yyyy")}  #dirty but required to get unique dates

# Initializing table & column header
$body = @"
<div style="overflow-x:auto;">
<table>
<caption style="caption-side:bottom;text-align:left;padding-top: 15px">
<p>* - Backup session has been running over 24 hours without completion</p>
<p><span style="background-color: ZZkeygreenZZ">All backups completed successfully</span></p>
<p><span style="background-color: ZZkeyyellowZZ">Some or all backups completed with a warning</span></p>
<p><span style="background-color: ZZkeyorangeZZ">Some backups failed</span></p>
<p><span style="background-color: ZZkeyredZZ">All backups failed</span></p>
</caption>
<tr>
<th>Job Name</th>
"@
$body += $dates | %{"<th>" + $_ + " (GB)</th>"}
$body += @"
<th>Total Size</th>
</tr>
"@

# Loop through Jobs
foreach ($job in $jobs){
    # Pulling previously gathered backup sessions & usage by Job Id
    $files = $file_info | ?{$_.JobId -eq $job.Id}
    $sessions = $session_info | ?{$_.JobId -eq $job.Id}
    $rps = $rp_info | ?{$_.JobId -eq $job.Id}

    # Beginning new row
    $body += @"
<tr>
<th>$($job.Name)</th>
"@

    # Looping through each date
    foreach ($date in $dates){
        # Finding backup sessions & usage by date
        $file = $files | ?{$_.CreationTime.Tostring("M/d/yyyy") -eq $date}
        $session = $sessions | ?{$_.CreationTime.Tostring("M/d/yyyy") -eq $date}
        $rp = $rps | ?{$_.CreationTime.Tostring("M/d/yyyy") -eq $date}
        $childJob = $rp | Select-Object ChildJobId -Unique
        if ($rp.RestorePointId.count -eq 0){
            # Single restore point
            $count = 0
        } else {
            # Single session per job. Dividing RP count by agent backup count
            $count = $rp.RestorePointId.count / $childJob.ChildJobId.count
        }
        #Write-Host "###################"
        #Write-Host "Date: $date"
        #Write-Host "Job: $($job.name)"
        #Write-Host "Child Job count: $($childJob.ChildJobId.count)"
        #Write-Host "RP count: $($rp.RestorePointId.count)"
        #Write-Host "Overtime: $($session.Overtime)"
        #Write-Host "Success: $($session.SuccessResult)"
        #Write-Host "Warning: $($session.WarningResult)"
        #Write-Host "Failed: $($session.FailedResult)"
        #Write-Host "Compared Count: $count"
        # Add color to output depending on results
        switch ($true)
        {
            # Success
            (($session.SuccessResult -ge $count) -and ($session.Overtime -ne $true)) {
                $body += $subHead01suc
                #Write-Host "Result: SUCCESS"
                break
            }
            # Warning
            ($session.WarningResult -ge $count) {
                $body += $subHead01war
                #Write-Host "Result: WARNING"
                break
            }
            # Success/Warning
            (($session.SuccessResult + $session.WarningResult) -ge $count) {
                $body += $subHead01war
                #Write-Host "Result: WARNING"
                break
            }
            # Success/Fail
            (($session.SuccessResult + $session.FailedResult) -ge $count) {
                $body += $subHead01mix
                #Write-Host "Result: MIX"
                break
            }
            # Warning/Failed
            (($session.WarningResult + $session.FailedResult) -ge $count) {
                $body += $subHead01mix
                #Write-Host "Result: MIX"
                break
            }
            # Failed
            ($session.FailedResult -ge $count) {
                $body += $subHead01err
                #Write-Host "Result: FAILED"
                break
            }
            # Backup session still running over 24 hours
            ($session.Overtime -eq $true) {
                $body += $subHead01war
                #Write-Host "Result: WARNING"
                break
            }
            # No matches found
            default {
                $body += $subHead01
                #Write-Host "Default Result: Neutral"
            }
        }
#pause
        # Has a session been running over 24 hours without completion?
        $rpoMonitor = ""
        if ($session.Overtime -eq $true){
            $rpoMonitor = " *"
        }

        # Adding data to row
        $body += ($file.BackupSizeGB -join ' / ') + $rpoMonitor

    }  #end date loop

    # Adding total size and ending row
    $body += $subHead01total + ($files | Measure-Object BackupSizeGB -Sum).Sum + " GB" + $subHead02

}  #end jobs loop

# Ending table
$body += @"
</table>
</div>
"@

# Combine HTML Output
$htmlOutput = $headerObj + $bodyTop + $body + $footerObj
# Fix Details
$htmlOutput = $htmlOutput.Replace("ZZbrZZ","<br />")
# Remove trailing HTMLbreak
$htmlOutput = $htmlOutput.Replace("$($HTMLbreak + $footerObj)","$($footerObj)")
# Color Report Header and Tag Email Subject
if ($htmlOutput -match "#FB9895") {
    # If any errors paint report header red
    $htmlOutput = $htmlOutput.Replace("ZZhdbgZZ","#FB9895")
} ElseIf ($htmlOutput -match "#ffd96c") {
    # If any warnings paint report header yellow
    $htmlOutput = $htmlOutput.Replace("ZZhdbgZZ","#ffd96c")
} ElseIf ($htmlOutput -match "#FFA500") {
    # If any warnings paint report header orange
    $htmlOutput = $htmlOutput.Replace("ZZhdbgZZ","#FFA500")
} ElseIf ($htmlOutput -match "#00b050") {
    # If any success paint report header green
    $htmlOutput = $htmlOutput.Replace("ZZhdbgZZ","#00b050")
} Else {
    # Else paint gray
    $htmlOutput = $htmlOutput.Replace("ZZhdbgZZ","#626365")
}
# Add color code to index key
#Green
$htmlOutput = $htmlOutput.Replace("ZZkeygreenZZ","#00b051")
#Yellow
$htmlOutput = $htmlOutput.Replace("ZZkeyyellowZZ","#ffd96c")
#Orange
$htmlOutput = $htmlOutput.Replace("ZZkeyorangeZZ","#FFA500")
#Red
$htmlOutput = $htmlOutput.Replace("ZZkeyredZZ","#FB9895")

# Save HTML Report to File
if ($saveHTML) {
  $htmlOutput | Out-File $pathHTML -Force
  if ($launchHTML) {
    Invoke-Item $pathHTML
  }
}