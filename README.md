# Qualys Script Repo
![Qualys](https://img.shields.io/badge/Qualys-ED2E26?style=flat&logo=qualys&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=iterm2&logoColor=white)
> Author: Gabriel Wolf

### [`Initialize-QualysPassword.ps1`](Initialize-QualysPassword.ps1)
Initialize a password associated with the current user for secure connections to Qualys API. 

### [`Get-QualysAsset.ps1`](Get-QualysAsset.ps1)
Get Qualys Asset by name.

### [`Parse-Duplicates.ps1`](Parse-Duplicates.ps1)
Takes a Qualys export csv ```export.csv``` and parses it to find all (non-Cloud Agent) duplicates. 

### [`Purge-Duplicates.ps1`](Purge-Duplicates.ps1)
Uses ```Parse-Duplicates.ps1``` and purges all duplicate (non-Cloud Agent) assets. 

### [`setup-qualys-ports.sh`](setup-qualys-ports.sh)
Opens up the Quays correlation ports on Linux systems for de-duplication.
