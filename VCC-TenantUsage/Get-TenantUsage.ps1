<#
.SYNOPSIS
	Veeam Cloud Connect (VCC) Tenant Usage

.DESCRIPTION
    This script will allow you to pull VCC tenant usage
    including space used in Backup Repositories and SOBR (Performance & Capacity).

.PARAMETER Server
	Cloud Connect Server (Veeam Backup & Replication)

.PARAMETER Username
	Veeam Backup & Replication Administrator account username

.PARAMETER Password
	Veeam Backup & Replication Administrator account password

.PARAMETER Credential
	Veeam Backup & Replication Administrator account PS Credential Object

.PARAMETER Test
	Flag allowing self-signed certificates (insecure)

.OUTPUTS
    - Get-TenantUsage returns a PowerShell object containing VCC tenant usage
	- Get-TenantUsage returns a PowerShell object containing network share test results

.EXAMPLE
	Get-TenantUsage.ps1 -Server "vbr.contoso.local" -Username "contoso\jdoe" -Password "password"

	Description 
	-----------     
	Pulling VCC Tenant usage using the specified VBR server using the username/password specified

.EXAMPLE
	Get-TenantUsage.ps1 -Server "vbr.contoso.local" -Username "contoso\jdoe"

	Description 
	-----------     
	If the password is omitted, you will be asked for it later in the script

.EXAMPLE
	Get-TenantUsage.ps1 -Server "vbr.contoso.local" -Credential (Get-Credential)

	Description 
	-----------     
	PowerShell credentials object is supported

.EXAMPLE
	Get-TenantUsage.ps1 -Server "vbr.contoso.local" -Credential $Credential -Test

	Description 
	-----------     
	Executes a test to see if network shares are configured properly

.EXAMPLE
	Get-TenantUsage.ps1 -Server "vbr.contoso.local" -Credential $Credential -Verbose

	Description 
	-----------     
	Verbose output is supported

.NOTES
	NAME:  Get-TenantUsage.ps1
	VERSION: 1.0
	AUTHOR: Chris Arceneaux
	TWITTER: @chris_arceneaux
	GITHUB: https://github.com/carceneaux

.LINK
	https://arsano.ninja/
#>
[CmdletBinding(DefaultParametersetName="UsePass")]
param(
    [Parameter(Mandatory=$true)]
		[String] $Server,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $Username,
	[Parameter(Mandatory=$false)]
		[string] $Password = $true,
	[Parameter(Mandatory=$true, ParameterSetName="UseCred")]
		[System.Management.Automation.PSCredential]$Credential,
	[Parameter(Mandatory=$false)]
		[Switch] $Test
)

Function Get-TenantUsageForExtent {
    param(
        $share,
        $folder,
        $extent,
        $Credential
    )
    
    Write-Verbose "Mapping temp drive to network share: $share"
    New-PSDrive -Name "temp" -PSProvider FileSystem -Root "$share" -Credential $Credential -ErrorAction SilentlyContinue | Out-Null
    
    # Is network share working properly?
    if (-Not (Test-Path -Path "temp:")) {
        Write-Error "Network share is not configured: $share"
        Write-Warning "Please run the '-Test' flag to make sure all network shares are configured properly."
        
        # Exiting script
        Disconnect-VBRServer
        exit
    }

    # Testing if tenant has backups in the extent
    if (Test-Path -Path "temp:\$folder") {
        Set-Location -Path "temp:\$folder"
    } else {
        Write-Verbose "Tenant - $folder - has no backups in this network share: $share"
        
        # Removing temp drive
        $location | Set-Location
        Remove-PSDrive -Name "temp" -Confirm:$false

        # Returning null object
        return $null
    }
    
    # Testing if tenant has Backup Job metadata files in the extent
    $jobs = @()
    if ((Get-ChildItem *vbm -Recurse).count -gt 0) {
        
        Write-Verbose "Searching share for Backup Job metadata files"
        $vbms = Get-ChildItem *vbm -Recurse

        # Loop through Backup Jobs metadata files
        foreach ($vbm in $vbms) {

            # Parsing Backup Job metadata XML
            [xml]$jobXml = Get-Content $vbm
            $jobName = $jobXml.BackupMeta.Backup.JobName
            Write-Verbose "Parsing metadata for Backup Job: $jobName"

            # Pulling backup file information
            $storages = $jobXml.BackupMeta.BackupMetaInfo.Storages.Storage

            # Looping through backup files in Backup Job
            $files = @()
            foreach ($storage in $storages){
                
                # Parsing storage information
                [xml]$stats = $storage.Stats
                
                # If BackupSize is 0, use filesystem size
                if ($stats.CBackupStats.BackupSize -eq 0){
                    $backupSize = (Get-ChildItem "$($vbm.DirectoryName)\$($storage.FilePath)").Length
                } else {
                    $backupSize = $stats.CBackupStats.BackupSize
                }
                
                # Creating PSObject for backup files
                $file = New-Object PSObject -Property @{
                    Id = $storage.Id
                    FilePath = $storage.FilePath
                    ExternalContentMode = $storage.ExternalContentMode
                    CreationTime = $storage.CreationTime
                    CreationTimeUtc = $storage.CreationTimeUtc
                    ModificationTime = $storage.ModificationTime
                    BackupSize = $backupSize
                    DataSize = $stats.CBackupStats.DataSize
                    DedupRatio = $stats.CBackupStats.DedupRatio
                    CompressRatio = $stats.CBackupStats.CompressRatio
                }
                $files += $file
            }

            # Creating PSObject for Backup Job
            $job = New-Object PSObject -Property @{
                Id = $jobXml.BackupMeta.Backup.Id
                Name = $jobName
                Files = $files
            }
            $jobs += $job
        }
    }

    # Finding untracked files in Backup Job as these use up space
    $untrackedFiles = $null
    if ($jobs.Count -gt 0) {
        
        # Gathering all files from filesystem in VCC Tenant folder excluding folders and metadata files
        $fileSystem = Get-ChildItem -Recurse | Where-Object {$_.PSIsContainer -eq $false} | Where-Object {$_.Name -notlike "*vbm"}

        # Gathering all Backup Job known filenames
        $fileBackup = $jobs.Files.FilePath
        
        # Determining if there are untracked files
        $untrackedFiles = $fileSystem | Where-Object {$fileBackup -notcontains $_}
        if ($untrackedFiles) {
            $untrackedFileSize = ($untrackedFiles | Measure-Object Length -Sum).Sum
        } else {
            $untrackedFileSize = 0
        }
    }

    # Removing temp drive
    $location | Set-Location
    Remove-PSDrive -Name "temp" -Confirm:$false

    # Returning PSobject with usage
    return New-Object PSObject -Property @{
        Id = $extent.Id
        Name = $extent.Name
        Status = $extent.Status
        Jobs = $jobs
        UntrackedFiles = $untrackedFiles
        UntrackedFileSize = $untrackedFileSize
    }
}

Function Test-NetworkShares {
    param(
        $repos,
        $Credential
    )

    # Finding SOBRs
    $sobrs = $repos | Where-Object {($_.GetType()).Name -eq "VBRScaleOutBackupRepository"}

    # Looping through SOBRs
    $toFix = @()
    foreach ($sobr in $sobrs) {

        Write-Verbose "Checking SOBR: $($sobr.name)"
        
        # Finding Extents for SOBR
        $extents = $sobr.Extent

        # Looping through Extents
        foreach ($extent in $extents) {

            Write-Verbose "Checking Extent: $($extent.name)"
            # Matching extent with repository server
            $vbrServer = Get-VBRServer | Where-Object { $_.Id -eq $extent.Repository.Info.HostId }
            if ($vbrServer.IsLocal()) {
                $address = (Get-VBRServerSession).Server
            } else {
                $address = $vbrServer.Name
            }
            $share = "\\$address\$($extent.Repository.Id.Guid)"

            Write-Verbose "Testing network share: $share"
            New-PSDrive -Name "temp" -PSProvider FileSystem -Root "$share" -Credential $Credential -ErrorAction SilentlyContinue | Out-Null
            
            # Is network share working properly?
            if (Test-Path -Path "temp:"){
                Write-Host -ForegroundColor Green "SUCCESS: $share"
                Remove-PSDrive -Name "temp"
            } else {
                Write-Host -ForegroundColor Red -BackgroundColor Black "FAILED: $share"
                # Creating PSObject for Backup Resource
                $obj = New-Object PSObject -Property @{
                    Id = $extent.Repository.Id.Guid
                    SOBR = $sobr.Name
                    Extent = $extent.Name
                    Server = $address
                    Share = $share
                    LocalDir = $extent.Repository.FriendlyPath
                    PowerShell = "New-SmbShare -Name `"$($extent.Repository.Id.Guid)`" -Path `"$($extent.Repository.FriendlyPath)`" -ReadAccess `"$($Credential.UserName)`""
                }
                $toFix += $obj
            }
        }
    }
    
    # Is there anything to fix?
    if ($toFix) {
        Write-Host ""
        Write-Host "The following network shares need to be created/fixed so the script will work properly:"
        Write-Host ""
        $toFix
    } else {
        Write-Host ""
        Write-Host "All network shares are working properly. No further configuration is necessary."
    }
    
    # Exiting script
    Disconnect-VBRServer
    exit
}

# Initializing Variables
$location = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-Not $Credential) {
    if ($Password -eq $true) {
        $secPass = Read-Host "Enter password for '$($Username)'" -AsSecureString
        
    } else {
        $secPass = ConvertTo-SecureString $Password -AsPlainText -Force
    }
    $Credential = New-Object System.Management.Automation.PSCredential ($Username, $secPass)
}

# Registering VeeamPSSnapin if necessary
$registered = $false
foreach ($snapin in (Get-PSSnapin)) {
    if ($snapin.Name -eq "veeampssnapin") { $registered = $true }
}
if ($registered -eq $false) { add-pssnapin veeampssnapin }

Write-Verbose "Connecting to VBR Server"
Connect-VBRServer -Server $server -Credential $Credential

# Validating successful connection to VBR server
if (-Not (Get-VBRServerSession)){
    Write-Warning "$($server): Connection failed - Please make sure the server was not misspelled and valid credentials were used."
    
    # Exiting script
    exit
}

Write-Verbose "Retrieving all CC Tenants"
$tenants = Get-VBRCloudTenant

Write-Verbose "Retrieving all CC Repositories"
$repos = Get-VBRBackupRepository -ScaleOut
$repos += Get-VBRBackupRepository

# Testing network shares?
if ($test) {
    Test-NetworkShares -repos $repos -credential $Credential
}

Write-Verbose "Beginning loop through CC Tenants"
$usage = @()
foreach ($tenant in $tenants) {

    Write-Verbose "Pulling usage for Tenant: $($tenant.Name)"

    # Loop through each Tenant Backup Resource (repository)
    $resources = @()
    foreach ($resource in $tenant.Resources) {
        
        Write-Verbose "Currently evaluating Backup Resource: $($resource.RepositoryFriendlyName)"
        
        # Match resource to repo
        $repo = $repos | Where-Object { $_.Id -eq $resource.Repository.Id }

        # Checking type of repo and proceeding accordingly
        if ("CBackupRepository" -eq ($repo.GetType()).Name) {
            Write-Verbose "$($repo.Name) is not a SOBR"

            # Creating PSObject for Backup Resource
            $obj = New-Object PSObject -Property @{
                Id = $resource.Id
                Name = $resource.RepositoryFriendlyName
                RepositoryQuota = $resource.RepositoryQuota
                UsedSpace = $resource.UsedSpace
                UsedSpacePercentage = $resource.UsedSpacePercentage
                IsSOBR = $false
                HasCapacityTier = $false
                Repository = $null
            }
            $resources += $obj
        }
        elseif ("VBRScaleOutBackupRepository" -eq ($repo.GetType()).Name) {
            Write-Verbose "$($repo.Name) is a SOBR"
            # Is Capacity Tier enabled?
            if ($repo.EnableCapacityTier -eq $false) {
                Write-Verbose "Capacity Tier is disabled. Capturing all usage as Performance Tier."
                $capacityTier = $false  #Is Capacity Tier enabled for the SOBR?
                $repoUsage = $null
            }
            else {
                Write-Verbose "Capacity Tier is enabled. Checking Backup Job metadata for usage."
                $extents = $repo.Extent
                $capacityTier = $true  #Is Capacity Tier enabled for the SOBR?
                
                # Loop through extents searching for metadata files with usage
                $repoUsage = $null
                foreach ($extent in $extents) {
                    
                    Write-Verbose "Checking tenant usage in $($extent.Name)"
                    
                    # Matching extent with repository server
                    $vbrServer = Get-VBRServer | Where-Object { $_.Id -eq $extent.Repository.Info.HostId }
                    $folder = $($resource.RepositoryQuotaPath)
                    if ($vbrServer.IsLocal()) {
                        $address = (Get-VBRServerSession).Server
                        $path = "\\$address\$($extent.Repository.Id.Guid)"
                    } else {
                        $path = "\\$($vbrServer.Name)\$($extent.Repository.Id.Guid)"
                    }
                    
                    
                    # Determine extent type
                    switch ($extent.Repository.Info.Type) {
                        "WinLocal" {
                            Write-Verbose "Windows direct attached storage found: Checking CIFS/SMB share for Backup Files"
                            $repoUsage += Get-TenantUsageForExtent -share $path -folder $folder -extent $extent -credential $Credential
                            break
                        }
                        "LinuxLocal" {
                            Write-Verbose "Linux direct attached storage found: Checking CIFS/SMB share for Backup Files"
                            $repoUsage += Get-TenantUsageForExtent -share $path -folder $folder -extent $extent -credential $Credential
                            break
                        }
                        "CifsShare" {
                            Write-Verbose "CIFS share found: Checking for Backup Files"
                            $repoUsage += Get-TenantUsageForExtent -share $path -folder $folder -extent $extent -credential $Credential
                            break
                        }
                        default {
                            # Terminating VBR server session
                            Disconnect-VBRServer
                            
                            # We can't pull accurate usage if we can't process the extent
                            Throw "$($extent.Name): An unsupported extent type ($($extent.Repository.info.Type)) is being used"
                        }
                    }
                }
            }

            # Creating PSObject for Backup Resource
            $obj = New-Object PSObject -Property @{
                Id = $resource.Id
                Name = $resource.RepositoryFriendlyName
                RepositoryQuota = $resource.RepositoryQuota
                UsedSpace = $resource.UsedSpace
                UsedSpacePercentage = $resource.UsedSpacePercentage
                IsSOBR = $true
                HasCapacityTier = $capacityTier
                Repository = $repoUsage
            }
            $resources += $obj
        }
        else {
            # Terminating VBR server session
            Disconnect-VBRServer
            
            # We can't pull accurate usage if the repo type hasn't been added to this script
            Throw "$($repo.Name): Unable to determine repository type"
        }
    }

    ##### Now totaling Block/Object usage numbers #####
    Write-Verbose "Usage collection for $($tenant.Name) is complete. Summing up usage numbers now."
    
    # Zeroing out space usage
    $usedBlock = 0
    $usedObject = 0
    # Looping through Backup Resources
    foreach ($resource in $resources) {

        # Is SOBR?
        if ($resource.IsSOBR) {
            
            # Is Capacity Tier enabled?
            if ($resource.HasCapacityTier) {
                
                # Capacity Tier detected - pulling SOBR Perf/Cap Tier values
                $performance =  $resource.Repository.Jobs.Files | Where-Object {$_.ExternalContentMode -eq 0}
                $total = ($performance | Measure-Object BackupSize -Sum).Sum
                $total = [math]::round($total / 1Mb) #convert from bytes to MB
                $usedBlock += $total

                $capacity = $resource.Repository.Jobs.Files | Where-Object {$_.ExternalContentMode -eq 1}
                $total = ($capacity | Measure-Object BackupSize -Sum).Sum
                $total = [math]::round($total / 1Mb) #convert from bytes to MB
                $usedObject += $total

                # Checking for untracked files - rare occurrence but it takes up space. If you see this, please investigate with Veeam support.
                $total = [math]::round($resource.Repository.UntrackedFileSize / 1Mb) #convert from bytes to MB
                $usedBlock += $total
            } else {
                
                # No Capacity Tier so pulling UsedSpace at face value
                $usedBlock += $resource.UsedSpace
            } 
        } else {
            
            # No Capacity Tier so pulling UsedSpace at face value
            $usedBlock += $resource.UsedSpace
        }
    }

    # Creating PSObject for Tenant usage
    $obj = New-Object PSObject -Property @{
        Id = $tenant.Id
        Name = $tenant.Name
        Description = $tenant.Description
        Enabled = $tenant.Enabled
        UsedBlockMB = $usedBlock
        UsedObjectMB = $usedObject
        Resources = $resources
    }
    $usage += $obj
}

# Terminating VBR server session
Disconnect-VBRServer

# Returning usage
return $usage
