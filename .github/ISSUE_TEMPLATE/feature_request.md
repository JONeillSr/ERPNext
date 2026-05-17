---
name: Feature request
about: Suggest a new capability or improvement for the ERPNext-Azure deployment scripts
title: '[FEATURE] '
labels: ['enhancement', 'needs-triage']
assignees: ''
---

## What problem are you trying to solve?

<!--
Describe the situation you're in and what's making it harder than it should be.
Examples:
- "I need to deploy multiple ERPNext sites in the same VNet, currently the script
   creates a new MariaDB per VM and that's wasteful"
- "I want to use Azure Database for MariaDB instead of a self-hosted instance"
- "I need to deploy ERPNext to Azure Government cloud"
- "I need automated SSL/Let's Encrypt configuration during initial deploy"
- "I want to integrate with an existing Azure Key Vault that has different RBAC"
-->

## What would the ideal solution look like?

<!--
Describe what you'd want the script to do. A specific command-line example is helpful.

```powershell
.\Deploy-ERPNextToAzure.ps1 -SomeNewParameter 'whatever' ...
```
-->

## Why does this belong in the script (vs. a separate workflow)?

<!--
Help us understand whether this is a natural fit for the script's scope.
The scripts focus on: provisioning Azure infrastructure for ERPNext on a VM
with MariaDB, Redis, Frappe v15, and nginx, plus optional WordPress integration.

Out-of-scope topics include:
- ERPNext app customization (DocTypes, Workflows, Reports - use the Frappe UI)
- Backup/restore strategies (use bench backup or Azure Backup directly)
- High-availability clustering (a different architecture entirely)
- Workload migration FROM other ERPNext instances (data migration is per-engagement)
-->

## Alternatives you've considered

<!--
What workarounds have you tried? What other tools or scripts almost solved it?
- Manual portal steps
- ARM/Bicep templates
- Other community PowerShell scripts
-->

## Are you willing to contribute?

<!--
- [ ] I can submit a PR for this
- [ ] I can help test a PR from someone else
- [ ] I'm requesting it but can't contribute
-->

## Additional context

<!--
- Links to relevant Frappe/ERPNext community discussions
- Links to relevant Azure docs
- Related GitHub issues or PRs (in this repo or others)
- Screenshots if a portal capability is involved
-->
