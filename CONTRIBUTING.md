# Contributing to ERPNext-on-Azure

Thanks for your interest in improving this repo. Whether you're filing a bug, suggesting a feature, or sending a pull request, here's what to expect.

## Reporting bugs

Open an issue using the **Bug report** template. The template asks for:

- Exact command you ran
- Script output (or attached `.log` file)
- Environment details (PowerShell version, Az module version, region, etc.)
- Where in the deployment the failure occurred
- ERPNext-specific context (VM size, Frappe version, deployment mode)

The more specific you can be, the faster issues get resolved. ERPNext deployment touches a lot of moving parts (Azure networking, Ubuntu package management, Python/Node.js versions, Frappe Framework, MariaDB, Redis, supervisor, nginx) — these details matter when narrowing down where things went wrong.

## Suggesting features

Open an issue using the **Feature request** template. Be explicit about the problem you're trying to solve, not just the solution. A clear problem statement makes it easier to spot when an existing capability already addresses your need, or when the "ideal" solution would create downstream complexity.

## Pull requests

PRs are welcome. Before submitting:

1. **Open an issue first for non-trivial changes.** This avoids wasted effort on changes that don't fit the project's scope.
2. **Run PSScriptAnalyzer locally** before pushing:
   ```powershell
   Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   ```
   The GitHub Actions workflow runs the same check on every PR.
3. **Test against a real Azure subscription.** The deploy script provisions actual Azure resources and installs Frappe v15 on a real Ubuntu VM. Static analysis alone won't catch installation-time failures. A full deploy + teardown cycle in a sandbox subscription is the right baseline test.
4. **Update CHANGELOG.md** under the `[Unreleased]` section with a brief description of your change.
5. **Bump the script version** in the `$ScriptVersion` variable and the `Version:` line of the comment header if your change is user-visible.

## Code style

The scripts deliberately favor clarity over cleverness:

- **Prose comments explain *why*, not *what*.** Anyone can read PowerShell; explain the reasoning behind non-obvious choices, especially Azure platform quirks and Frappe installation idiosyncrasies (there are many of both).
- **Function names follow `Verb-Noun` convention** using approved verbs (`Get-Verb` for the list).
- **Helper functions live above the main flow.** No anonymous script blocks for anything that has a name worth giving.
- **Errors throw early with actionable messages.** When the script fails, the error message should tell the user what to do, not just what went wrong.
- **Comments document platform-specific gotchas in place.** When you discover that, say, `bench setup production` must run twice on Ubuntu 24.04, the comment explaining that lives in the script next to the code that handles it, not in a separate doc.

## Scope

This repo is specifically for **automated deployment of ERPNext to Azure on a self-hosted Ubuntu VM**. Out of scope:

- **ERPNext application customization** — DocTypes, workflows, custom apps, accounting setup. Use the Frappe UI, Frappe Framework docs, or community forums.
- **Backup and restore** — Use `bench backup` or Azure Backup directly. This script provisions infrastructure; ongoing operations are out of scope.
- **High-availability ERPNext clustering** — A multi-VM HA topology is a fundamentally different architecture. The single-VM pattern this script provisions is for small-to-medium businesses, not enterprise-scale clustering.
- **Data migration from other ERPNext instances** — Migration tooling depends heavily on source environment specifics. Tackle that as a separate per-engagement effort.
- **Application-layer integrations** — WooCommerce/Shopify/marketplace connectors that need ERPNext app configuration. We provide the infrastructure substrate; app-level integration belongs in the WordPress plugin or in custom Frappe apps.

If you have a use case that's adjacent but distinct (e.g., Azure Database for MariaDB instead of self-hosted, deployment to AKS, multi-tenant SaaS sites), consider a separate repo or a major fork.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE) that covers this project.

## Acknowledgments

This toolkit grew out of real consulting engagements where the manual portal-based ERPNext-on-Azure setup proved tedious enough to automate. Many of the platform quirks the scripts handle (Ubuntu 24.04 PEP 668 restrictions, the need to run `bench setup production` twice, the supervisor group naming on modern Frappe versions) were discovered through trial and error during those deployments. Each fix is documented inline in the scripts so future maintainers can understand what's intentional vs. accidental.
