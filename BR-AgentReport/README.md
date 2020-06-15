# Veeam Agent Backup Report

## Author

Chris Arceneaux (@chris_arceneaux)

## Function

This script pulls all agent-based backup information accessible on the VBR server and generates a report from it.

## Known Issues

* Script is designed to be executed on VBR server. Code can be easily added to execute remotely.

## Requirements

* Veeam Backup & Replication 10
* Windows account with Administrator access to the Veeam server

## Usage

* Edit script and configure *User Variables*
* Run script:

`.\New-Veeam-Agent-Backups-Report.ps1`
