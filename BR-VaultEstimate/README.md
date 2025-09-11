# Generate Vault Storage Estimation Report

## Author

Chris Arceneaux (@chris_arceneaux)

## Function

This script will search through all Veeam Backup & Replication (VBR) backups on the connected server and compile a report of the total size of all backups and the average daily change rate percentage.

This information must be input with the [Veeam calculator](https://www.veeam.com/calculators/simple/vdc/vault/machines), along with retention requirements, to estimate the size of Veeam Data Cloud Vault storage required.

***NOTE:*** Script is designed to be run locally on the VBR server. It could be modified to execute the script on a remote server where the Veeam Backup & Replication console is installed.

## Known Issues

* *None*

## Requirements

* Veeam Backup & Replication
  * v12.3 or newer
* Windows account with Administrator access to the Veeam server

## Usage

```powershell
Get-Help .\Get-VaultEstimate.ps1 -Full
```
