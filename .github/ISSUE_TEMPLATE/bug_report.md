---
name: Bug report
about: Something isn't working as expected during ERPNext deployment or teardown
title: '[BUG] '
labels: ['bug', 'needs-triage']
assignees: ''
---

## What happened?

<!-- A clear, concise description of the bug. -->

## What did you expect to happen?

<!-- What should the script have done instead? -->

## Steps to reproduce

<!-- Exact command line you ran (you can redact sensitive IDs with x's). -->

```powershell
.\Deploy-ERPNextToAzure.ps1 ...
```

## Script output / error

<!--
Paste the relevant log output. Truncate to the failure point if it's long.
Either inline (in a code block) or attach the .log file the script generates.
The deployment log is the most useful artifact for diagnosing issues.
-->

```
<paste here>
```

## Where in the deployment did it fail?

<!-- Check the one that matches: -->

- [ ] Pre-flight checks (context, VNet validation, CIDR overlap)
- [ ] Resource Group / Key Vault creation
- [ ] Networking (NSG, Public IP, VNet/subnet)
- [ ] VM creation
- [ ] ERPNext bash installation script (Frappe/Bench/MariaDB setup)
- [ ] Post-install verification
- [ ] WordPress integration / API config
- [ ] Teardown
- [ ] Not sure

## Environment

- **Script:** <!-- Deploy-ERPNextToAzure.ps1, Remove-ERPNextAzureDeployment.ps1, Select-AzureContext.ps1, Import-ERPNextCategories.ps1 -->
- **Script version:** <!-- visible in the banner, e.g., v1.6.5 -->
- **PowerShell version:** <!-- run `$PSVersionTable.PSVersion` -->
- **OS (where you ran the script):** <!-- Windows 11, etc. -->
- **Az PowerShell module version:** <!-- run `(Get-Module Az -ListAvailable).Version` -->
- **Azure region:** <!-- e.g., westus2, eastus -->
- **VM size used:** <!-- e.g., Standard_D2s_v6 (default) -->

## ERPNext deployment context

- **Deployment mode:** <!-- Public (default) / -PrivateOnly with -ExistingVNetName -->
- **Existing VNet (if -PrivateOnly):** <!-- name and address space -->
- **Subnet CIDR you specified:** <!-- e.g., 10.0.2.0/27 -->
- **MariaDB version expected:** <!-- usually 10.6+ on Ubuntu 24.04 -->
- **Frappe version:** <!-- usually v15 -->
- **Did you use -UseKeyVault?:** <!-- Yes/No -->
- **Did you use -ConfirmContext?:** <!-- Yes/No -->

## Azure environment context

- **Subscription type:** <!-- Pay-As-You-Go / Enterprise Agreement / CSP / Visual Studio / Free -->
- **Anything unusual in your VNet topology?:** <!-- peerings, custom route tables, NSG rules outside the script's control, etc. -->
- **Are you joining an existing VNet that hosts other workloads?:** <!-- Yes/No, brief description -->

## Ubuntu / Frappe-specific (if the failure is during installation)

- **bench setup production output:** <!-- The installation script generates structured logs. The relevant lines usually mention nginx, supervisor, redis, mariadb, or bench. -->
- **Did the sentinel file get created?:** <!-- The script looks for /home/<adminuser>/install-complete.sentinel to confirm success -->

## Additional context

<!--
Anything else that might help diagnose:
- Have you run the script successfully before on this client?
- Did anything change in your Azure environment recently?
- Are there other resources in the target RG that might conflict?
- Screenshots if a portal step is involved
-->
