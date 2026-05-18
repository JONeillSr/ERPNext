## Highlights

Adds **`Add-LetsEncryptSSL.ps1`** — a standalone companion script that provisions production-grade SSL on a deployed ERPNext-on-Azure instance using Let's Encrypt wildcard certificates via DNS-01 challenge against Azure DNS, authenticated through a User-Assigned Managed Identity (no secrets to manage).

## What's new

### `Add-LetsEncryptSSL.ps1` (v1.0.2)

The architecture is opinionated for the typical Azure Innovators / SMB-consulting scenario: the ERPNext VM is reachable only via VPN (not the public internet), so HTTP-01 challenges are impossible — DNS-01 is the only viable path.

After provisioning, the script:

- Creates a User-Assigned Managed Identity and grants it **DNS Zone Contributor** on the public zone only (least privilege)
- Installs certbot and certbot-dns-azure into `/opt/certbot` (avoids Ubuntu 24.04 PEP 668 system-pip restriction)
- Requests a wildcard cert covering `*.<zone>` and `<zone>` via DNS-01 challenge
- Updates the Frappe site's `site_config.json` with cert paths plus `host_name` and `domains`
- Switches Frappe to `dns_multitenant` mode and regenerates nginx
- Installs a systemd timer for twice-daily renewal checks with a deploy hook to reload nginx after each renewal

**Total marginal cost: $0/month.** Let's Encrypt certs are free, the managed identity is free, and DNS API calls during cert renewal are effectively free (a handful of queries every 60-90 days).

## Four ERPNext-on-Ubuntu gotchas the script handles

Through real-world testing against a production deployment, four issues surfaced that aren't documented in any single place online. The script bakes in the workarounds with explanatory comments so future maintainers know what each protects against:

1. **`pyopenssl<26` version pin** — pyOpenSSL 26.0.0+ removed the deprecated `X509Extension` class that the certbot `acme` library still references. Without the pin, `certbot --version` throws on the first invocation.

2. **`azure-mgmt-dns==8.2.0` version pin** — A breaking constructor change in `azure-mgmt-dns` 9.0.0 is incompatible with the current `certbot-dns-azure` plugin. Without the pin, certbot raises a `TypeError` during the DNS challenge.

3. **`log_format main` patch to `/etc/nginx/nginx.conf`** — Frappe's generated nginx config references a log format named `main`, but Ubuntu's default `nginx.conf` only defines `combined`. After regenerating with SSL enabled, `nginx -t` fails with `[emerg] unknown log format "main"`. The script idempotently patches `nginx.conf`.

4. **`bench config dns_multitenant on`** — Frappe runs in port-based multitenancy by default, which silently ignores `ssl_certificate` config entirely (no port 443 listener generated). Switching to DNS-based multitenancy is required for SSL listeners to exist at all.

## Sentinel-based VM script success detection

The script's helper for executing bash on the VM (`Invoke-VMScript`) uses sentinel-based success detection. Every bash block sent to the VM is automatically prefixed with `set -e` and suffixed with `echo '__STEP_OK__'`. If that exact marker isn't in stdout, the PowerShell side throws with full stdout/stderr captured.

This replaces the previous pattern of string-matching stderr for words like "Error" and gracefully handles all the failure modes hit during development:

- bash aborts on first `set -e` failure before producing stderr
- script runs but tools printed warnings matching "Error" (false positives)
- script runs partially, exits cleanly without finishing (silent partial failure)

No more "DEPLOYMENT COMPLETE" reports while nothing actually happened on the VM.

## Parameters renamed (`-SiteName` split into two)

Reflecting the reality that the public hostname and the internal Frappe site directory are typically different:

- **`-PublicFQDN`** — The hostname users type in their browser (e.g., `erpnext.contoso.com`). Goes into `site_config.json` as `host_name`. nginx serves SSL on this name.
- **`-FrappeSiteDir`** — The internal Frappe site directory name (e.g., `jtcustomtrailers.local`). Optional — auto-detected by scanning `frappe-bench/sites/`.

## Recommended usage (two-pass)

```powershell
# Pass 1: Test with Let's Encrypt staging (no rate limits, untrusted cert)
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'erpnext-prod-vm' `
    -ERPNextVMResourceGroup 'erpnext-prod-rg' `
    -PublicZoneName 'contoso.com' `
    -PublicZoneResourceGroup 'contoso-dns-rg' `
    -PublicFQDN 'erpnext.contoso.com' `
    -ContactEmail 'admin@contoso.com' `
    -UseStaging

# Pass 2: Once verified, re-run for a real production cert (drop -UseStaging)
```

## Prerequisites

To use the script, you must already have:

- A working ERPNext-on-Azure deployment (from `Deploy-ERPNextToAzure.ps1`)
- A **public DNS zone** for your domain hosted in Azure DNS
- **VPN access to the ERPNext VM** for browser-based verification
- VPN-connected clients need a way to resolve the public FQDN to the VM's private IP — see [Setup-AzureP2SVPN](https://github.com/JONeillSr/Setup-AzureP2SVPN) for the split-horizon DNS + forwarder scripts

## Documentation

- **README.md**: SSL script added to file table, "What it does" paragraph, Step 4 in Quick Start, full parameter table with two-pass usage example
- **Quick-Start-Guide.md**: new Step 2.5 between Access and Initial Config — walks through the staging→production flow with prerequisites, internal steps, and verification

## Full changelog

See [CHANGELOG.md](https://github.com/JONeillSr/ERPNext/blob/main/CHANGELOG.md#170---2026-05-18) for the detailed entry.
