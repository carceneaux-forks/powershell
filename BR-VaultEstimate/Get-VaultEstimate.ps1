<#
.SYNOPSIS
Veeam Data Cloud Vault Storage Estimation Report

.DESCRIPTION
This script will search through all Veeam Backup & Replication (VBR) backups on the connected server and compile a report of the total size of all backups and the average daily change rate percentage which can be input the Veeam calculator (https://www.veeam.com/calculators/simple/vdc/vault/machines) to estimate the size of Veeam Data Cloud Vault storage required. Script is designed to be run locally on the VBR server.

.PARAMETER Include
Names of Veeam backup repositories to include in the report. Multiple names can be separated by commas. If not specified, all repositories will be included.

.PARAMETER Exclude
Names of Veeam backup repositories to exclude from the report. Multiple names can be separated by commas. If not specified, no repositories will be excluded.

.OUTPUTS
Get-VaultEstimate returns a PowerShell Object containing a summary of the data and also exports a detailed CSV file containing information about each machine in each backup located in the same folder the script is run from.

.EXAMPLE
Get-VaultEstimate.ps1

Description
-----------
Run the script without any parameters. All backups located in all repositories will be included in the report.

.EXAMPLE
Get-VaultEstimate.ps1 -Include "Primary Repository","Offsite Repository" -Exclude "Test Repository"

Description
-----------
Include and Exclude parameters are supported. In this example, only backups located in "Primary Repository" and "Offsite Repository" will be included in the report while any backups located in "Test Repository" will be excluded from the report.

.EXAMPLE
Get-VaultEstimate.ps1 -Verbose

Description
-----------
Verbose output is supported

.NOTES
NAME:  Get-VaultEstimate.ps1
VERSION: 1.0
AUTHOR: Chris Arceneaux
TWITTER: @chris_arceneaux
GITHUB: https://github.com/carceneaux

.LINK
https://www.veeam.com/calculators/simple/vdc/vault/machines

.LINK

#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]] $Include = $false,
    [Parameter(Mandatory = $false)]
    [string[]] $Exclude = $false
)

Function Confirm-Value {
    param($value)

    # If value exists, return value.
    if ($value) {
        return $value
    }
    else {
        # Otherwise, return zero.
        return 0
    }
}

# Initializing object
$detail = [System.Collections.ArrayList]::new()

# Retrieving repositories
$repositories = Get-VBRBackupRepository
$repositories += Get-VBRBackupRepository -ScaleOut

# Retrieving backups
$backups = Get-VBRBackup

# Looping through jobs
foreach ($backup in $backups){
    Write-Verbose "Processing backup: $($backup.Name)"

    # Determining repository name
    $repositoryName = ($repositories | Where-Object {$_.Id -eq $backup.RepositoryId}).Name

    # If Exclude parameter is used, skip backup if repository is in Exclude list
    if (($Exclude -ne $false) -and ($repositoryName -in $Exclude)){
        Write-Verbose "Skipping backup because repository $($repositoryName) is in the Exclude list"
        continue
    }
    # If Include parameter is used, skip backup if repository is not in Include list
    if (($Include -ne $false) -and ($repositoryName -notin $Include)){
        Write-Verbose "Skipping backup because repository $($repositoryName) is not in the Include list"
        continue
    }

    # Retrieving backup files
    $files = $backup.GetAllChildrenStorages()

    # Retrieving machines in backup
    $machines = $backup.GetObjectOibsAll()
    Write-Verbose "Found $($machines.count) machines in backup"

    # If only one machine, process backup and continue
    if (1 -eq $machines.count){
        # Determine most recent full backup
        $full = $files | Where-Object {($true -eq $_.IsFull) -or ($true -eq $_.IsFullFast)} | Select-Object -First 1

        # Determine most recent incremental backups
        $incrementals = $files | Where-Object {$true -eq $_.IsIncrementalFast} | Select-Object -First 5

        # Determine average daily change rate percentage
        if (($null -eq $full) -or ($null -eq $incrementals)){
            # change rate cannot be calculated if there is no full or no incrementals
            $average = 0
        } else {
            $rates = [System.Collections.Generic.List[float]]::new()
            foreach ($incremental in $incrementals){
                $rates.Add(
                    $incremental.Stats.BackupSize / $full.Stats.BackupSize
                )
            }
            # Convert decimal to percentage by multiplying 100
            $average = ($rates | Measure-Object -Average).Average * 100
            Write-Verbose "Average daily change rate for $($machines.Name) is $([math]::round($average,2))%"
            Clear-Variable -Name ("rates", "incremental", "incrementals")
        }

        # Adding machine info to detailed object
        $object = [PSCustomObject] @{
            Name = $machines.Name
            SizeBytes = $machines.ApproxSize
            DailyChangeRate = [math]::round($average, 2) #round to 2 decimal places
            LatestBackup = ($files | Select-Object -First 1).CreationTime
            Id = $machine.ObjId
            BackupId = $backup.Id
            RepositoryId = $backup.RepositoryId
            RepositoryName = ($repositories | Where-Object {$_.Id -eq $backup.RepositoryId}).Name
        }
        [ref] $null = $detail.Add($object)
        Clear-Variable -Name ("object", "full", "average", "files")

        # Continue to next backup
        continue
    }

    # Looping through machines
    foreach ($machine in $machines){

        # Limit backup files to a specific machine
        $machineFiles = $files | Where-Object {$_.ObjectId -eq $machine.ObjId}

        # Sort newest to oldest
        $machineFiles = $machineFiles | Sort-Object CreationTime

        # Determine most recent full backup
        $full = $machineFiles | Where-Object {($true -eq $_.IsFull) -or ($true -eq $_.IsFullFast)} | Select-Object -First 1

        # Determine most recent incremental backups
        $incrementals = $machineFiles | Where-Object {$true -eq $_.IsIncrementalFast} | Select-Object -First 5

        # Determine average daily change rate percentage
        if (($null -eq $full) -or ($null -eq $incrementals)){
            # change rate cannot be calculated if there is no full or no incrementals
            $average = 0
        } elseif ($true -eq $machine.IsVApp){
            # change rate is skewed for VApps
            $average = 0
        } else {
            $rates = [System.Collections.Generic.List[float]]::new()
            foreach ($incremental in $incrementals){
                $rates.Add(
                    $incremental.Stats.BackupSize / $full.Stats.BackupSize
                )
            }
            # Convert decimal to percentage by multiplying 100
            $average = ($rates | Measure-Object -Average).Average * 100
            Write-Verbose "Average daily change rate for $($machine.Name) is $([math]::round($average,2))%"
            Clear-Variable -Name ("rates", "incremental", "incrementals")
        }

        # Adding machine info to detailed object
        $object = [PSCustomObject] @{
            Name = $machine.Name
            SizeBytes = $machine.ApproxSize
            DailyChangeRate = [math]::round($average, 2) #round to 2 decimal places
            LatestBackup = ($machineFiles | Select-Object -First 1).CreationTime
            Id = $machine.ObjId
            BackupId = $backup.Id
            RepositoryId = $backup.RepositoryId
            RepositoryName = ($repositories | Where-Object {$_.Id -eq $backup.RepositoryId}).Name
        }
        [ref] $null = $detail.Add($object)
        Clear-Variable -Name ("object", "full", "average", "machineFiles")
    } # End looping through machines

} # End looping through backups

# Exporting information to CSV
$dateString = (Get-Date).ToString("MM-dd-yyyy")
$filename = "backup-info_$dateString.csv"
$detail | Export-Csv $filename -NoTypeInformation
Write-Host "Detailed information about each machine in each backup has been exported to $filename" -ForegroundColor Green

# Adding together size of all machines to protect
$total = ($detail.SizeBytes | Measure-Object -Sum).sum

# Converting bytes to TB
$totalTb = [math]::round($total / 1Tb, 2) #convert from bytes to TB

# Determining average daily change rate across all machines removing empty values
# NOTE: Change rate is averaged, not weighted by size
$changerate = ($detail.DailyChangeRate | Where-Object {$_ -ne 0} | Measure-Object -Average).Average

# Adding job and total size to output variable
return [PSCustomObject] @{
    TotalTB = Confirm-Value -Value $totalTb
    DailyChangeRate = [math]::round($changerate, 2)
}
