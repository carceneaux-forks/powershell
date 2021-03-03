<#
.SYNOPSIS
	Veeam Service Provider Console (VSPC) Tenant Onboarding

.DESCRIPTION
	This script will allow you to migrate all Backup Policies
	from one VSPC instance to another. This can be highly beneficial
	when consolidating VSPC appliances.

.PARAMETER Source
	Source VSPC Server IP or FQDN

.PARAMETER Username
	Source VSPC Portal Administrator account username

.PARAMETER Password
	Source VSPC Portal Administrator account password

.PARAMETER Credential
	Source VSPC Portal Administrator account PS Credential Object

.PARAMETER Port
	Source VSPC Rest API port

.PARAMETER AllowSelfSignedCerts
	Flag allowing self-signed certificates (insecure)

.OUTPUTS
	New-Tenant returns a PowerShell object containing VBR Backup usage

.EXAMPLE
	VSPC-MigratePolicies.ps1 -Server "vac.contoso.local" -Username "vac\jsmith" -Password "password"

	Description
	-----------
	Migrate Backup Policies on the specified VSPC servers using the username/password specified

.EXAMPLE
	VSPC-MigratePolicies.ps1 -Server "vac.contoso.local" -Credential (Get-Credential)

	Description
	-----------
	PowerShell credentials object is supported

.EXAMPLE
	VSPC-MigratePolicies.ps1 -Server "vac.contoso.local" -Credential $cred_source -Port 9999

	Description
	-----------
	Connecting to a VSPC server using a non-standard API port

.EXAMPLE
	VSPC-MigratePolicies.ps1 -Server "vac.contoso.local" -Username "vac\jsmith" -Password "password"

	Description
	-----------
	Connecting to a VSPC server that uses Self-Signed Certificates (insecure)

.NOTES
	NAME:  New-Tenant.ps1
	VERSION: 0.6
	AUTHOR: Chris Arceneaux
	TWITTER: @chris_arceneaux
	GITHUB: https://github.com/carceneaux

.LINK
	https://arsano.ninja/

.LINK
	https://helpcenter.veeam.com/docs/vac/rest/post_backuppolicies.html?ver=30
#>
[CmdletBinding(DefaultParametersetName="UsePass")]
param(
    [Parameter(Mandatory=$true)]
		[String] $Server,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $Username,
	[Parameter(Mandatory=$true, ParameterSetName="UsePass")]
		[String] $Password = $True,
	[Parameter(Mandatory=$true, ParameterSetName="UseCred")]
		[System.Management.Automation.PSCredential]$Credential,
	[Parameter(Mandatory=$false)]
		[Int] $Port = 1281,
	[Parameter(Mandatory=$false)]
		[Switch] $AllowSelfSignedCerts
)

Function Get-AuthToken{
	param(
		[String] $vspc,
		[String] $user,
		[String] $pass,
		[String] $port
	)

	# POST - /token - Authorization
	[String] $url = "https://" + $vspc + ":" + $port + "/token"
	Write-Verbose "Authorization Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Content-Type", "application/x-www-form-urlencoded")
	$body = "grant_type=password&username=$user&password=$pass"
	try {
		$response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -Body $body -ErrorAction Stop
		return $response.access_token
	} catch {
		Write-Error "`nERROR: Authorization Failed! - $vspc"
		Exit 1
	}
	# End Authorization

}

Function Get-BackupPolicies{
	param(
		[String] $vspc,
		[String] $port,
		[String] $token
	)

	# GET /v2/backupPolicies
	[String] $url = "https://" + $vspc + ":" + $port + "/v2/backupPolicies"
	# not filtering out predefined policies to make sure we have 1 to 1 matches
	Write-Verbose "VSPC Get Backup Policies Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "Bearer $token")
	try {
		$response = Invoke-RestMethod $url -Method 'GET' -Headers $headers -ErrorAction Stop
		return $response
	} catch {
		Write-Error "`nERROR: Retrieving Backup Policies - $vspc - Failed!"
		Exit 1
	}
	# End Backup Policies Retrieval

}

Function New-BackupPolicy{
	param(
		[String] $vspc,
		[String] $port,
		[String] $token,
		[String] $policy
	)

	# POST /v2/backupPolicies
	[String] $url = "https://" + $vspc + ":" + $port + "/v2/backupPolicies"
	Write-Verbose "VSPC New Backup Policy Url: $url"
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "Bearer $token")
	$headers.Add("Content-Type", "application/json")
	try {
		$response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -Body $policy -ErrorAction Stop
		return $response
	} catch {
		Write-Error "`nERROR: Creating Backup Policy Failed!`n$policy"
		Exit 1
	}
	# End New Backup Policy

}

# Allow Self-Signed Certificates (not recommended)
if ($AllowSelfSignedCerts){
	add-type -TypeDefinition  @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# Enables use of PSCredential objects
if (-Not $Credential) {
    if ($Password -eq $true) {
        $Password = Read-Host "Enter password for '$($Username)'"

    }
}
# Extract username/password from Credential object
else {
	$Username = $Credential.getNetworkCredential().username
	$Password = $Credential.getNetworkCredential().password
}

# Authenticating to VSPC
$token = Get-AuthToken -VSPC $Server -Username $Username -Password $Password -Port port

# Retrieving Source Backup Policies
$policies = Get-BackupPolicies -VSPC $Server -Port $port -Token $token

