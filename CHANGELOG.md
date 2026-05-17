# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.6.5] - 2026-05-16

### Improved

- **Pre-flight check for subnet-fits-in-VNet.** When using `-ExistingVNetName`, the script now verifies that the requested `-SubnetAddressPrefix` actually fits inside the VNet's address space *before* attempting to add the subnet via the Azure API. Previously, a mismatch produced a cryptic Azure error (`NetcfgSubnetRangeOutsideVnet`) mid-deployment.

  The new check inspects all VNet address prefixes (a VNet can have multiple), confirms at least one prefix is broad enough to contain the requested subnet, and if none qualifies, throws a clear error with the exact PowerShell commands to expand the VNet's address space. The expansion command is non-disruptive — existing subnets and resources are unaffected when you add an additional prefix to a VNet.

  Example improved error message:
  ```
  Requested subnet 10.0.2.0/27 does not fit inside the VNet's address space (10.0.0.0/23).
  Either pass -SubnetAddressPrefix with a CIDR inside that range, or expand the VNet's
  address space first with:

    $vnet = Get-AzVirtualNetwork -Name 'jtcustomtr-2e886f0313-vnet' -ResourceGroupName 'JTC-Prod-WP-WestUS2-rg'
    $vnet.AddressSpace.AddressPrefixes.Add('10.0.2.0/24')
    $vnet | Set-AzVirtualNetwork

  Then re-run this deploy. Expanding a VNet's address space is non-disruptive - existing
  subnets and resources are unaffected.
  ```

### Why this matters for hub-spoke / shared-VNet topologies

When ERPNext deploys into a VNet owned by another team or service, the VNet's address space was sized for that other workload. Adding an ERPNext subnet might or might not fit. The pre-flight check turns a 30-second confusing failure into immediate, actionable guidance.

---

## [1.6.4] - 2026-05-16

### Fixed

- **Test-CIDROverlap still crashing in v1.6.3** with the same `Cannot convert value "-1" to type "System.UInt64"` error, despite the rewrite to "uint64 throughout." The root cause turned out to be PowerShell's hex-literal parsing: `[uint64]0xFFFFFFFF` doesn't do what it looks like. PowerShell parses `0xFFFFFFFF` first as the *narrowest* numeric type that fits (which is `[int]` interpreted as a signed value, giving `-1` since the high bit is set), then casts that `-1` to `[uint64]`. The cast goes through .NET's numeric conversion which throws because `-1` isn't representable as an unsigned type.

- **The fix has two parts:**
  1. **Replaced hex literals with decimal:** `[uint64]4294967295` instead of `[uint64]0xFFFFFFFF`. Decimal literals avoid the parser-narrowing trap entirely.
  2. **Replaced bitshift operators with multiplication:** instead of `($byte -shl 24)`, the code now does `($byte * 16777216)`. Mathematically identical but bypasses PowerShell's operator precedence around mixed-type shifts, which is where intermediate signed values were creeping in.

- **Made the overlap check non-fatal:** wrapped the `Test-CIDROverlap` call in a try/catch. If the helper math fails for any future reason, the script logs a warning and proceeds. Azure's API has its own overlap validation; the helper is a nice-to-have early-warning, not a safety-critical check. The deployment shouldn't abort because of a pre-check helper bug.

### Why this took two attempts to fix

PowerShell's numeric type system is full of subtle traps when mixing integer widths. The first attempt assumed that "casting to `[uint64]` is enough"; in reality, the cast happens *after* the literal has already been narrowed to a problematic intermediate type. The lesson: avoid hex literals in PowerShell numeric math entirely; use decimal, and prefer arithmetic (`*`, `+`) over bitwise (`-shl`, `-bor`, `-bnot`) when working with values that span integer widths.

---

## [1.6.3] - 2026-05-16

### Fixed

- **`Test-CIDROverlap` crashed on every invocation with `Cannot convert value "-1" to type "System.UInt64"`.** The function used PowerShell's `-bnot` operator on a `[uint32]` mask to compute the host portion of an address range. PowerShell's `-bnot` doesn't preserve unsigned semantics — when applied to `[uint32]0`, it returns the signed integer `-1`, not the unsigned `0xFFFFFFFF` that the math needs. Subsequent operations tried to convert `-1` to `[uint64]` (because PowerShell widens to the larger type in mixed operations) and threw an exception, taking down the entire subnet-creation step in PrivateOnly+ExistingVNet mode.

- **The fix:** rewrote the address-range computation using arithmetic instead of bitwise complement. The new logic: `blockSize = 2^hostBits`, `mask = 0xFFFFFFFF - (blockSize - 1)`, `end = start + blockSize - 1`. All math happens in `[uint64]` which has plenty of headroom for any 32-bit IPv4 arithmetic and never produces negative intermediates.

- **Verified against six test cases** including the actual JTC scenarios (`10.0.2.0/27` vs `10.0.0.0/25` WordPress appsubnet, vs `10.0.1.0/25` dbsubnet), edge cases (fully contained `/16` in `/8`, adjacent `/27`s that don't overlap, partial overlap of `/27` with `/28`), and trivial cases. All correct.

### Why this bug existed

The original implementation was modeled on a C-style bitwise mask computation that works fine in any language with proper unsigned types. PowerShell's mixed-type arithmetic and the way it handles `-bnot` on unsigned values isn't well-documented and the breakage isn't visible until runtime. The arithmetic-based replacement is also clearer to read.

---

## [1.6.2] - 2026-05-16

### Quality of life

- **Auto-rename RG/VM when location changes.** When `-Location` is set to anything other than `eastus` and the user accepts the default `-ResourceGroupName` and `-VMName`, the script now substitutes the new location into those names (e.g., `JTC-prod-erpnext-eastus-rg` → `JTC-prod-erpnext-westus2-rg`). Previously, deploying to westus2 with default names produced resources named `*-eastus-*` in westus2, which was technically functional but confusing in the portal and inconsistent with the rest of the naming convention. Users who pass explicit `-ResourceGroupName` and `-VMName` are unaffected.
- Fixed the in-script `.EXAMPLE` for private-network deployment that incorrectly showed `-Region 'westus2'` (which would have failed — the actual parameter name is `-Location`).

---

## [1.6.1] - 2026-05-16

### Fixed (Remove-ERPNextAzureDeployment.ps1 → 1.3.1)

- **Teardown hung in `Blocked` state when `Remove-AzResourceGroup -AsJob` was launched.** PowerShell background-job runspaces do **not** inherit `$ConfirmPreference` or `$PSDefaultParameterValues` from the parent session. Even though the teardown script sets `$ConfirmPreference = 'None'` at the top when `-Force` is passed, the `-AsJob` runspace started fresh with `ConfirmPreference = 'High'`. The cmdlet inside the job tried to prompt for confirmation, the prompt had nowhere to go (no console attached to the job), and the job sat in `Blocked` state indefinitely.

  The v1.2.1 fix from earlier today addressed a *different* bug in the same area (polling for the wrong state name), but did not address the underlying confirmation-suppression issue in the job runspace. That bug only manifested when the job's runspace defaults didn't happen to match what the cmdlet needed.

- **The fix:** replaced `Remove-AzResourceGroup -AsJob` with `Start-Job -ScriptBlock { ... }`. The script block explicitly sets `$ConfirmPreference = 'None'` and `$PSDefaultParameterValues['*:Confirm'] = $false` *inside the runspace* before calling the cmdlet. The block also re-imports `Az.Resources` and `Az.Accounts` and sets the Az context explicitly, since the job runspace has neither of those by default.

- **Added a `Blocked`-state guard:** if the job sits in `Blocked` state for more than 2 minutes, the script now aborts with a clear error message and the synchronous-fallback command for the operator to run. This prevents an infinite poll loop in case some future scenario introduces a different prompt-suppression failure.

### Why this was timing-sensitive

`Remove-AzResourceGroup -AsJob` does *some* of its setup work in the parent runspace before delegating to the background runspace. Whether that included consuming `-Force` and `-Confirm:$false` flags before the runspace boundary, or after, appears to vary by Az.Resources version. v1.2.1 was tested with a session where the flags were honored; this session got the unlucky path where they weren't.

### Deploy script version bumped to 1.6.1 for bundle alignment

No functional changes in the deploy script. Bundle versions stay aligned so the latest tested deploy + matching teardown ship together.

---

## [1.6.0] - 2026-05-16

**Private network deployment mode.** Add support for deploying ERPNext as a private-only VM with no public IP, designed for production access via Azure VPN Gateway and/or peered VNets. Previous deployments exposed port 80 (and SSH) to the internet with NSG source-IP restriction; this release adds a fully private deployment path that's reachable only from inside the VNet.

### Deploy-ERPNextToAzure.ps1 → 1.6.0

**New parameters:**

- `-PrivateOnly` — skip public IP creation entirely. NSG rules tighten to allow inbound only from the `VirtualNetwork` service tag (which automatically includes the VNet's own address space, all peered VNets, and any VPN client address pools — so peering or VPN access "just works" without rule updates).

- `-ExistingVNetName` — join an existing VNet rather than creating a fresh one. Use this to put ERPNext in the same network as other services it needs to talk to (e.g., a WordPress App Service with VNet integration, a MySQL Flexible Server).

- `-ExistingVNetResourceGroup` — for when the existing VNet lives in a different RG than where you want ERPNext deployed. Common pattern: VNet in a shared infrastructure RG, ERPNext in its own dedicated RG. The script validates that the VNet's region matches the deployment region and refuses to proceed if they don't.

- `-SubnetName` (default `erpnext-subnet`) — name of the subnet to use within the existing VNet. Reused if it already exists, created if it doesn't.

- `-SubnetAddressPrefix` (default `10.0.2.0/27`) — CIDR for a newly-created subnet. The script validates that the requested prefix doesn't overlap any existing subnet in the target VNet before attempting creation.

**Behavior changes:**

- The VM's NIC is created without a public IP when `-PrivateOnly` is set. The install still works via `Invoke-AzVMRunCommand` because that uses Azure's Resource Manager control plane, not VM networking.
- The result object now includes both `IPAddressKind` (`Public` or `Private`) and `IPAddress` fields. The legacy `PublicIP` field is preserved for backward compatibility with v1.5.x consumers but is more accurately just "the IP people use to reach ERPNext."
- Final summary clearly distinguishes private vs public IP and reminds the operator that private IPs require VPN/VNet access.

**Added helper:**

- `Test-CIDROverlap` — pure-PowerShell CIDR overlap detection used to validate new subnet placement against existing subnets in the target VNet. No external dependencies.

### Remove-ERPNextAzureDeployment.ps1 → 1.3.0

When ERPNext is deployed into a shared VNet, the subnet that the script created lives in that VNet's resource group — NOT the ERPNext RG. Deleting the ERPNext RG leaves the subnet behind, blocking future redeployments at the same prefix. New parameters handle this:

- `-ExternalVNetName` / `-ExternalVNetResourceGroup` / `-ExternalSubnetName` — after the RG deletion completes, the script verifies the subnet has no remaining IP configurations attached (sanity check that the RG deletion actually removed the NIC), then removes the subnet from the external VNet.

If any IP configurations are still attached when subnet deletion is attempted, the script refuses to delete and surfaces a warning — that means the RG deletion didn't fully complete and investigation is needed before retry.

### Typical usage going forward

```powershell
# Private deployment into existing VNet (e.g., shared with WordPress)
.\Deploy-ERPNextToAzure.ps1 -ConfirmContext `
    -UseKeyVault -KeyVaultName 'JTC-prod-westus2-kv' `
    -Region 'westus2' `
    -PrivateOnly `
    -ExistingVNetName 'jtcustomtr-2e886f0313-vnet' `
    -ExistingVNetResourceGroup 'jtcustomtr-rg'

# Matching teardown that cleans up the external subnet too
.\Remove-ERPNextAzureDeployment.ps1 -Force -RemoveLocalArtifacts `
    -KeyVaultName 'JTC-prod-westus2-kv' -PurgeKeyVault `
    -ExternalVNetName 'jtcustomtr-2e886f0313-vnet' `
    -ExternalVNetResourceGroup 'jtcustomtr-rg'
```

### Backward compatibility

All new parameters are optional. Existing v1.5.x call patterns continue to work unchanged and produce identical behavior (public IP + fresh isolated VNet). No changes required to consumers of the result object — the `PublicIP` field is preserved alongside the new `IPAddress` / `IPAddressKind` fields.

---

## [1.5.6] - 2026-05-16

### Added (Remove-ERPNextAzureDeployment.ps1 → 1.2.2)

- **Orphaned soft-deleted Key Vault warning.** After deleting a Resource Group, the teardown now scans for Key Vaults that were in that RG and are now in Azure's soft-deleted state. If any are found AND the user didn't pass `-PurgeKeyVault`, a yellow warning block appears in the summary explaining what's reserved, why a future deploy will collide, and the exact command to purge.

  Sample output:
  ```
  ---------------------------------------------------------------
  NOTE: Soft-deleted Key Vault(s) remain
  ---------------------------------------------------------------
    JTC-prod-eastus-kv

    These vault names are reserved for 90 days by Azure's soft-delete.
    Re-deploying with the same name will fail until they are purged.

    To purge, re-run this script with:
      .\Remove-ERPNextAzureDeployment.ps1 -Force `
          -KeyVaultName 'JTC-prod-eastus-kv' -PurgeKeyVault

    Or via Azure portal: Key Vault service > Manage deleted vaults
  ---------------------------------------------------------------
  ```

  Purging remains opt-in (because it's irreversible), but the user is no longer surprised when the next deploy fails with a name-collision error.

- Deploy script version bumped to 1.5.6 for bundle alignment; no functional changes.

---

## [1.5.5] - 2026-05-16

### Fixed

- **Teardown silently skipped the actual Resource Group deletion.** The `Remove-AzResourceGroup -AsJob` polling loop checked `while ($rgJob.State -eq 'Running')`, but the job starts in state `NotStarted` and only transitions to `Running` after the cmdlet begins work. The loop saw `NotStarted`, exited immediately, the script called `Receive-Job` and `Remove-Job -Force` (killing the still-pending job), then reported "Resource Group deleted" — all in under one second. The actual Azure resources were left intact.

  This bug was present in `Remove-ERPNextAzureDeployment.ps1` from 1.1.0 onward but only surfaced now. Earlier teardown runs in this conversation worked because the job happened to transition through `Running` quickly enough that the loop's first iteration caught it. The behavior is timing-sensitive and unreliable.

- **The fix:** The loop now waits while state is in any *non-terminal* state (anything other than `Completed`, `Failed`, `Stopped`), explicitly handles the `Failed` state by surfacing job errors, and **verifies the RG is actually gone via `Get-AzResourceGroup` before reporting success**. The verification step catches any future cmdlet quirk where the job might report `Completed` without having done its work.

### How to spot this bug if you suspect it

Real RG deletions with a VM in them take 3-10 minutes minimum. If your teardown script reports "Resource Group deleted" in less than 30 seconds, something's wrong — verify with `Get-AzResourceGroup -Name <name>` afterward.

---

## [1.5.4] - 2026-05-16

### Fixed

- **`bench setup production` must be run TWICE on Ubuntu 24.04.** The first invocation generates supervisor and nginx config files in `frappe-bench/config/` but returns exit 0 *before* creating the `/etc/supervisor/conf.d/` symlink, running `supervisorctl reread/update`, or finalizing the nginx config. The second invocation picks up where the first left off and completes the work. Both runs return exit 0 so `set -euo pipefail` cannot catch the silent half-completion.

  Without the second run, `supervisorctl status` shows no Frappe groups exist at all, gunicorn never starts, port 8000 is never listening, and nginx serves the "Sorry! We will be back soon" maintenance page to every request. The install reports success while ERPNext is unreachable.

- **Home directory permissions are now adjusted BETWEEN the two `bench setup production` runs**, not after, so that the nginx reload triggered by the second run can actually traverse `/home/${ADMIN_USER}`. Ubuntu 24.04 ships home dirs at mode 750; nginx (as `www-data`) needs at least `o+x` to reach the bench's `sites/.../public/` directory.

- **Removed the `bench setup nginx --yes` step.** It was redundant with `bench setup production` (which already runs the nginx setup internally as part of its workflow) and didn't help. The cleaner pattern is just: run `bench setup production` twice, do the chmod between them, then poll for port 8000.

- **Removed the manual supervisor-start logic from 1.5.3.** I had targeted the wrong supervisor group names (`frappe-bench-frappe-web:*` instead of `frappe-bench-web`). The correct names per the bench-generated supervisor.conf are `frappe-bench-redis`, `frappe-bench-web`, and `frappe-bench-workers`. But with the double-invocation fix in place, supervisor is brought up correctly by bench itself — we don't need to manage it manually at all.

### What the user sees now

After v1.5.4, an end-to-end deploy completes when port 8000 is verified up. Hitting `http://<public-ip>` after the script declares success returns the ERPNext login page. The "Sorry! We will be back soon" failure mode is closed.

### Diagnosis trail

Pre-existing VMs from earlier 1.5.x runs can be remediated without a re-deploy by running `bench setup production jtadmin --yes` manually on the VM. The script's second pass is equivalent to the user manually running this remediation command. Future deploys via v1.5.4 won't need manual intervention.

---

## [1.5.3] - 2026-05-16

### Attempted (incomplete fix)

- Targeted the wrong supervisor group names when trying to manually start Frappe processes after `bench setup production`. The supervisor groups are `frappe-bench-redis`, `frappe-bench-web`, and `frappe-bench-workers` — not `frappe-bench-frappe-web:*` and friends. v1.5.3 ran `supervisorctl start` against names that didn't exist and silently failed.
- Also tried to fix this by chmod-ing the home directory and running `supervisorctl reread/update`. The reread/update was actually a no-op because bench setup production hadn't yet written the supervisor config files in the right place.
- v1.5.4 supersedes this with the correct fix: run `bench setup production` twice, which is what the bench command does on its own when invoked a second time.

---

## [1.5.2] - 2026-05-16

### Fixed

- **`bench setup production` failed on Ubuntu 24.04 with PEP 668 enforcement.** Frappe Bench v15's `setup_production` step runs `sudo /usr/bin/python3 -m pip install ansible` without the `--break-system-packages` flag. On Ubuntu 24.04 (which ships Python 3.12 with PEP 668 enforcement), this fails with `error: externally-managed-environment`. The install made it through 9 of 10 steps — VM provisioning, MariaDB, Node.js, wkhtmltopdf, bench init, Frappe + ERPNext + HRMS install, Redis discovery — then bombed on the final supervisor/nginx setup.

- **Fix:** The install script now pre-installs `ansible` via `apt-get install -y ansible` before invoking `bench setup production`. When bench then tries to pip-install Ansible, the package is already present and bench proceeds without invoking the broken pip command. Apt-managed Ansible doesn't trigger PEP 668 because it's not a pip install.

### Why bench has this bug

Bench was written before Ubuntu 24.04 / PEP 668. On Ubuntu 22.04 and earlier, `sudo pip install` worked silently and installed packages system-wide. PEP 668 (April 2023) added a marker file `/usr/lib/python3.12/EXTERNALLY-MANAGED` that signals "don't install pip packages system-wide unless you really mean it." Bench hasn't been updated to handle this, so on 24.04 you have to either skip-or-pre-install the problematic packages, or pass `--break-system-packages` everywhere. Pre-installing via apt is the cleaner option.

This same issue affects any Frappe Bench install on Ubuntu 24.04, Debian 12, and other distros that ship PEP 668 enforcement. A workaround in the Frappe community is to remove the EXTERNALLY-MANAGED marker file, but that's globally permissive and not recommended. Pre-installing the specific packages bench needs is targeted.

---

## [1.5.1] - 2026-05-16

### Fixed

- **Diagnostic dump on install failure was always empty.** The deploy script's output-extraction logic filtered `$result.Value` entries by `$v.Code -like '*StdOut*'`, expecting Run Command to return separate stdout and stderr entries. But Run Command actually returns a single Value entry where `Code='ProvisioningState/succeeded'` and the *entire script output* — both stdout and stderr — lives in the `Message` field, separated by inline `[stdout]` and `[stderr]` markers. The filter matched nothing, so the diagnostic always reported "stdout was empty / stderr was empty" even when the script had produced hundreds of lines of output.
- **The fix parses the Run Command output format correctly:** concatenates all `Value[*].Message` strings, then uses regex to extract the content between the `[stdout]` and `[stderr]` markers. Falls back to treating the whole message as stdout if the markers aren't present.
- Increased the failure-output tail from 50 to 80 lines since most install failures happen during a multi-line operation (apt, pip, bench init) where context matters.

### Why this matters

Without this fix, every install failure surfaced as "the install didn't reach the sentinel — and by the way I have no idea why." The actual error was always sitting in the Run Command response; we just weren't extracting it. With the fix, the deploy script's output will show the actual bash error inline, so you don't need to make a follow-up `Invoke-AzVMRunCommand` call to retrieve `/var/log/erpnext-install.log` in 95% of cases.

---

## [1.5.0] - 2026-05-16

**First production-ready release.** This is the consolidation point after a long debugging session that took the toolkit from "deploys infrastructure" to "deploys infrastructure and reliably installs ERPNext end-to-end." See the per-component summaries below; the bug-hunt history that produced these capabilities is preserved in the patch-version entries that follow (1.1.0 through 1.4.7).

### Deploy-ERPNextToAzure.ps1 → 1.5.0

**Multi-tenant safety.** `-TenantId`, `-SubscriptionId`, `-SelectContext`, and `-ConfirmContext` parameters for safe operation across multiple Azure AD tenants. The script refuses to proceed when multiple subscriptions are accessible and none is pinned, and displays the active context before any destructive operation.

**Key Vault data-plane reliability.** Auto-grants Key Vault Secrets Officer to the current principal on vault creation. Polls for RBAC propagation. Self-heals when a stale Az token cache causes the secret write to authenticate as a different principal OID. Retry-with-backoff on `Set-AzKeyVaultSecret`. Probe secret name follows Key Vault's `^[0-9a-zA-Z-]+$` rule.

**Install reliability.** Frappe-managed Redis instances are started before `bench new-site`. Redis ports are discovered dynamically from `config/redis_*.conf` rather than hardcoded, making the script forward-compatible across Frappe versions (v15 uses 2 instances, v14 used 3, ports moved). Complex Redis startup runs from an embedded helper script (`/tmp/start-redis-instances.sh`) on the VM.

**Genuine success detection.** The bash install emits a sentinel line `ERPNEXT_INSTALL_STATUS=SUCCESS` only after every step completes; the deploy script scans stdout for that sentinel before reporting success. On failure, dumps last 50 lines of stdout, all stderr, and the exact `Invoke-AzVMRunCommand` to retrieve the full log from `/var/log/erpnext-install.log` on the VM.

**Parser/quoting hardening.** Eliminated PowerShell parser landmines in the bash-generation code (reserved-operator `<`, quad-apostrophe ambiguity, `@'`/`@"` here-string opener collision, orphan backslash-backtick runaway string). Complex bash blocks (SQL operations, site creation) live in PowerShell here-strings `@'...'@` which are fully literal.

### Remove-ERPNextAzureDeployment.ps1 → 1.2.0

Multi-tenant safety parameters at parity with the deploy script. Cross-subscription search when the target resource group isn't in the active subscription. Key Vault purge handles vaults orphaned outside their original resource group, polls every 30 seconds for completion (20-minute timeout), and provides clear remediation steps if it times out. `-Force` now genuinely suppresses all downstream confirmation prompts via `$ConfirmPreference = 'None'`.

### Select-AzureContext.ps1 → 1.1.0

Searches all accessible tenants and subscriptions for a name pattern via `-SearchName`, not just the active subscription. Actionable error output when subscriptions can't be found, including suggestions to authenticate additional tenants. Used by both deploy and teardown scripts for context resolution.

### Import-ERPNextCategories.ps1 → 1.1.0 (unchanged)

No changes in this release. Tracked here for completeness.

---

## [1.4.7] - 2026-05-16

### Fixed

- **The root cause of every parser failure from 1.4.3 onward.** An orphan `` \` `` (backslash-backtick) at the end of a `Write-LogMessage` string in the diagnostic-dump section was eating the closing `"` of that string, turning the line into a runaway double-quoted string that consumed the next ~500 lines of code. PowerShell's parser stayed in double-string state from line 1100 all the way to wherever the next unescaped `"` happened to appear, mis-parsing braces and parens inside what it thought was string content. PSScriptAnalyzer's reported errors at lines 1002, 1057, 1431, 1553, and 1575 were ALL downstream cascades from this single character.

  ```powershell
  # Wrong (eats closing quote, runs into next ~500 lines):
  Write-LogMessage "  Invoke-AzVMRunCommand -ResourceGroupName '$ResourceGroup' -VMName '$VMName' \`" -Level Error

  # Right:
  Write-LogMessage "  Invoke-AzVMRunCommand -ResourceGroupName '$ResourceGroup' -VMName '$VMName' \" -Level Error
  ```

- The `` \` `` was originally intended to suggest "backslash for line-continuation" to the user reading the error output. But inside a PowerShell double-quoted string, the backtick is the escape character, so `` `" `` is the escape sequence for a literal `"` — which silently ate the string's closing quote.

### How a one-character bug masqueraded as five different problems

Once `"` was escaped at line 1100, PowerShell's tokenizer thought the rest of the file (from line 1100 onward) was string content. Every `{`, `}`, `(`, `)`, `[`, `]`, and `"` that appeared in code from that point on was misinterpreted. The parser only realized something was wrong when it reached the end of the file still expecting a closing `"` — hence "missing terminator" at line 1553. PSScriptAnalyzer's earlier errors (missing brace at 1002, missing brace at 1057, unexpected token at 1431) were all the parser making increasingly wrong guesses about where it was. The real bug was 500 lines upstream from any reported error.

Lessons reinforced:

1. **PSScriptAnalyzer errors often point to symptoms, not causes.** The first reported error is sometimes hundreds of lines after the actual bug. Search backward from the first error for unterminated strings, mismatched braces, and stray escapes.
2. **`` \` `` (backslash-backtick) is never what you want.** If you need a literal backslash in PowerShell, just type `\`. If you need a literal backtick, escape it with another backtick: `` `` ``.
3. **Adding entries to the global "dangerous sequences" list:** `` `" `` inside a double-quoted string is the escape for `"`; an orphan one will eat your closing quote and turn the next thousand lines into a string.

---

## [1.4.6] - 2026-05-16

### Fixed

- **Strategic refactor: complex bash blocks now use PowerShell here-strings.** After repeated parser failures in different spots — `<` reserved operator (1.4.3), quad-apostrophe ambiguity (1.4.4), `@'` here-string opener (1.4.5), and now an "unexpected token" in seemingly clean single-quoted strings — it became clear that line-by-line PowerShell string arrays are too fragile for complex bash content. Every new pattern was a new landmine.
- **The fix:** The SQL block, Redis-startup block, and site-creation block are now constructed via PowerShell here-strings (`@'...'@`) which are fully literal — no tokenization, no operator parsing, no quote ambiguity. Each here-string is split into lines and concatenated to `$installLines`. PowerShell's parser sees the here-string content as opaque text and emits it verbatim into the bash script.
- **The Redis startup block** went a step further: it's now written to `/tmp/start-redis-instances.sh` on the VM as a separate bash helper script. The complex control flow (config discovery, parallel-ish startup, port wait loops, error reporting) lives entirely in pure bash. The install script just creates the helper and invokes it.

### Architecture notes

The install-script generation now uses three distinct construction methods, chosen for the content:

| Content type | Method | Why |
|---|---|---|
| Simple bash lines (echo, apt-get, single sudo) | String array element | Easy to read; works for low-complexity lines |
| Complex bash with quotes/redirection/special chars | PS here-string `@'...'@`, split into lines | Fully literal; no PS tokenization |
| Multi-step control flow (loops, conditionals) | Embedded bash helper script | Pure bash; isolated from PS entirely |

This layered approach should be more resilient to future content additions.

---

## [1.4.5] - 2026-05-16

### Fixed

- **`@'` here-string opener collision in SQL syntax.** The 1.4.4 fix used MySQL's standard `'root'@'localhost'` user-host syntax inside a PowerShell double-quoted string. PowerShell saw the `@'` substring and treated it as a here-string header opener (PowerShell here-strings: `@'...'@`) — then complained that characters appeared after the header. This is a PowerShell tokenizer quirk: the `@'` and `@"` sequences are matched even when they appear mid-string.
- **Switched to MySQL's double-quoted identifier form.** Changed `'root'@'localhost'` to `"root"@"localhost"`. MySQL accepts double-quoted strings as literals by default (without `ANSI_QUOTES` mode), so this is functionally equivalent. The full SQL block is now inside PowerShell single-quoted strings (where nothing is parsed), with no `@'` anywhere in the source — completely safe.

### Lessons learned (running tally)

PowerShell-generated bash scripts can hit parser issues with surprising sequences:
- `<` inside double-quoted strings → reserved redirection operator (fixed in 1.4.3)
- `''''` (four apostrophes) inside single-quoted strings → ambiguous (fixed in 1.4.4)
- `@'` or `@"` anywhere inside strings → here-string opener match (fixed in 1.4.5)

**Defensive rules going forward:**
1. Prefer single-quoted PowerShell strings for bash lines (no interpolation needed; nothing parsed)
2. When bash variable interpolation is needed, keep it on its own line and use backtick-escaped `` `${var} `` in double-quoted PS strings
3. Use bash heredocs to escape PowerShell's parser entirely for complex content
4. Avoid the literal character sequences `@'`, `@"`, `'@`, `"@`, `''''`, and unescaped `<`/`>` in any string

---

## [1.4.4] - 2026-05-16

### Fixed

- **PowerShell wouldn't parse the script (second case).** The MariaDB secure-installation block had this line:
  ```
  'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DELETE FROM mysql.user WHERE User='''';"',
  ```
  Four consecutive apostrophes (`''''`) inside a PowerShell single-quoted string. PowerShell's tokenizer treated this ambiguously — `''` is the escape for a literal `'` inside single quotes, but the parser couldn't decide whether `''''` was "two escaped apostrophes" or "close-string then open-string then close-string."
- **Rewrote the entire MariaDB block as bash heredocs.** Instead of `mysql -e "SQL with nested quotes"`, the new approach uses `mysql <<EOF` and passes SQL via stdin. This eliminates all the PowerShell-to-bash quote-escaping complexity for that block — the SQL inside the heredoc is read literally by mysql, no extra layers of escaping needed. Bonus: the bash is also significantly more readable.

### Notes on PowerShell-generated bash

This kind of bug is the recurring tax of generating bash inside PowerShell strings. As a general rule going forward: any time the bash would need nested SQL/JSON/quoted-string content, prefer heredocs over `-e` or `-c` flags. Heredocs treat their content as raw text, sidestepping both layers of escaping.

---

## [1.4.3] - 2026-05-16

### Fixed

- **Script wouldn't even parse: "The '<' operator is reserved for future use."** PowerShell's parser treats `<` inside double-quoted strings as a reserved redirection operator and refuses to parse the file. The 1.4.0 multi-tenant safety-gate error messages used `"-SubscriptionId <id>"` to show placeholder syntax to users. PowerShell saw the literal `<` and bailed at parse time, before any code could run.
- Replaced all `<placeholder>` notation with `[placeholder]` in error messages and user-facing help text across `Deploy-ERPNextToAzure.ps1` and `Select-AzureContext.ps1`. Square brackets read naturally as placeholder syntax and have no special meaning in PowerShell strings.

---

## [1.4.2] - 2026-05-16

### Fixed

- **Install hung waiting for a Redis port that doesn't exist in current Frappe.** Frappe v15 consolidated from three Redis instances (queue/cache/socketio on ports 11000/12000/13000) to two (queue and cache only), and moved the cache port from 12000 to 13000. The script hardcoded all three original ports and would wait 30 seconds for port 12000 before bailing — even though `bench init` had successfully created the correct two configs and `redis-server` was running on the correct ports.
- **Redis config discovery is now dynamic.** The script globs `config/redis_*.conf` after `bench init` to discover which Redis instances `bench` actually wants, then reads each config's `port` directive with grep+awk to determine which port to wait on. This is forward-compatible with whatever future Frappe versions decide to do with Redis topology.
- **Better failure diagnostics.** If a Redis instance fails to start, the script now dumps the contents of `/tmp/redis_*.log` to stderr so the actual startup error is visible in the deploy output, not buried in a file on the VM.

### Diagnosis notes (for posterity)

The earlier 1.4.0 install logic was based on an outdated assumption about Frappe's Redis topology. Confirming with a fresh `bench init` against version-15 showed:
- `config/redis_queue.conf` → `port 11000`
- `config/redis_cache.conf` → `port 13000`
- `config/redis_socketio.conf` → **does not exist**

The 1.4.0 script started Redis on 11000 (succeeded), 13000 (succeeded via the "cache" command but checking for it as "socketio"), and tried to start something on 12000 with a config file that doesn't exist (silent failure since the start command ran via `nohup ... &`). Then it waited on port 12000 forever.

---

## [1.4.1] - 2026-05-16

### Fixed

- **Diagnostic dump for install failures was broken.** When the deploy script tried to dump stderr/stdout after an install failure, `Write-LogMessage` threw "Cannot bind argument to parameter 'Message' because it is an empty string" — its `Mandatory` `[string]` parameter rejected empty values, even though empty stderr is a perfectly normal case. This swallowed the actual diagnostic output and made it impossible to see why the install failed.
- Added `[AllowEmptyString()]` attribute to `Write-LogMessage`'s `Message` parameter in both deploy and teardown scripts. This is a class-of-bug fix — any future place that logs potentially-empty content will work correctly.
- Rewrote the failure-output dump to iterate stdout/stderr line by line, with explicit empty-section markers (`(stdout was empty)` / `(stderr was empty)`) so the operator knows the dump itself succeeded even when one channel had no content.

---

## [1.4.0] - 2026-05-16

### Fixed

- **`bench new-site` failed with `redis.exceptions.ConnectionError: Error 111 connecting to 127.0.0.1:11000`.** Frappe requires three private Redis instances (ports 11000 queue, 12000 cache, 13000 socketio) to be running before `new-site` can succeed. These are *not* the system-level `redis-server` on port 6379; they are bench-managed instances whose configs are generated by `bench init` in `config/redis_*.conf`. The install script previously called `new-site` immediately after `bench init`, before those Redis instances had been started by anything.

  The install script now:
    1. Generates the Redis configs via `bench init` (unchanged)
    2. Starts the three Redis instances directly via `redis-server config/redis_*.conf &` in the background
    3. Polls each port until it responds to `PING` (30-second per-port timeout)
    4. Runs `new-site` and `install-app` with Redis available
    5. Shuts the standalone Redis instances down before `bench setup production` migrates them to supervisor management

- **Silent install failures reported as success.** `Invoke-AzVMRunCommand`'s outer `Status` field only reports whether the bash script was delivered and executed — *not* whether it exited 0. A bash script that failed midway would still return `Status=Succeeded` from Run Command's perspective. The deploy script previously trusted that status and reported "DEPLOYMENT SUCCESSFUL" even when the install had blown up.

  The install bash now emits a sentinel line `ERPNEXT_INSTALL_STATUS=SUCCESS` only on the success path (after all 10 steps complete). The deploy script scans the Run Command's stdout for that exact sentinel and refuses to declare success without it. On failure, the deploy dumps the last 50 lines of stdout plus all stderr, and shows the exact `Invoke-AzVMRunCommand` command to retrieve the full install log from the VM at `/var/log/erpnext-install.log`.

---

## [1.3.8] - 2026-05-15

### Fixed

- **Key Vault probe secret name violated naming rules.** The write-probe secret introduced in 1.3.3 used underscores (`___erpnext-deploy-probe___`), but Key Vault secret names must match `^[0-9a-zA-Z-]+$` (alphanumerics and hyphens only). Renamed to `erpnext-deploy-probe-access`.

---

## [1.3.7] - 2026-05-15

### Fixed

- **Teardown's `-Force` flag wasn't fully honored.** Despite `-Force` being passed to `Remove-ERPNextAzureDeployment.ps1`, the underlying `Remove-AzResourceGroup` (and potentially other Az cmdlets) still showed their own `[Y/N/A/L/S]` confirmation prompts mid-teardown. The script ran but stalled at every prompt waiting for input — not what unattended `-Force` is supposed to mean.
- When `-Force` is supplied, the script now sets `$ConfirmPreference = 'None'` and `$PSDefaultParameterValues['*:Confirm'] = $false` to suppress all downstream confirmation prompts globally, regardless of which cmdlet emits them. Added explicit `-Confirm:$false` to the `Remove-AzResourceGroup` call as well, belt-and-suspenders.

---

## [1.3.6] - 2026-05-15

### Fixed

- **Key Vault purge timeout was too aggressive.** Real-world testing showed `Remove-AzKeyVault -InRemovedState -Force` can legitimately take 10-15+ minutes to complete (Azure backend operation, no progress visibility). The previous 3-minute timeout from 1.3.5 would wrongly kill a successful in-flight operation.
- **Replaced blind timeout with active polling.** The teardown now polls `Get-AzKeyVault -InRemovedState` every 30 seconds. When the target vault disappears from the soft-deleted list, the purge is confirmed successful — regardless of whether the underlying cmdlet has returned. Timeout extended to 20 minutes. Periodic progress messages every 30 seconds so the operator knows the script is alive.

---

## [1.3.5] - 2026-05-15

### Fixed

- **Teardown hung indefinitely on Key Vault purge.** `Remove-AzKeyVault -InRemovedState -Force` can silently hang when the Az token cache has stale entries from prior `Connect-AzAccount` calls (the same multi-tenant token-cache issue that affected the deploy script's Key Vault writes). Common in consultant workflows where multiple client tenants get authenticated in the same PowerShell session. The cmdlet doesn't time out on its own; it just sits forever waiting on something that never returns.
- **Wrapped purge in a 3-minute timeout.** The purge now runs in a background job. If it doesn't complete in 180 seconds, the script aborts the job, reports failure, and surfaces the exact remediation steps (Az session reset, or the Azure portal "Manage deleted vaults" workaround).

---

## [1.3.4] - 2026-05-15

### Fixed

- **Teardown script hung on interactive `Location:` prompt during Key Vault purge.** `Get-AzKeyVault -VaultName <name> -InRemovedState` requires `-Location` as a mandatory parameter; without it, PowerShell silently prompts the user mid-teardown — easy to miss in a long-running script. The fix:
  - Capture the vault's location during the pre-delete `Get-AzKeyVault` call and reuse it for the soft-deleted lookup
  - In the orphaned-vault recovery path (where the RG was already deleted and we don't know the location), use the list-all-deleted parameter set instead and filter client-side by name. Slower but doesn't require `-Location`.

---

## [1.3.3] - 2026-05-15

### Fixed

- **Key Vault token-mismatch causing 403 after successful role assignment.** When the Az PowerShell session has had multiple `Connect-AzAccount` calls (common for consultants switching between client tenants), the token cache can return different tokens for different Key Vault cmdlets. The previous probe used `Get-AzKeyVaultSecret`, which would succeed under the user's identity, but the subsequent `Set-AzKeyVaultSecret` would authenticate as a different cached principal that hadn't been granted the role — producing a 403 with `Assignment: (not found)`.
- **Probe rewritten as a real write.** `Test-KeyVaultSecretAccess` now writes (and immediately removes/purges) a throwaway probe secret using the exact same cmdlet path the real workload uses. If the probe passes, the real writes are guaranteed to pass.
- **Self-healing for additional principals.** When a 403 reveals that an OID different from the one we just granted access to is actually making the call, the script extracts that OID from the error message and grants Key Vault Secrets Officer to it as well (up to 2 additional grants per run to prevent runaway role-grant loops).

### Added

- **Actionable failure remediation.** When all retries are exhausted, the error message now includes the exact PowerShell commands to clean the Az token cache (`Disconnect-AzAccount`, `Clear-AzContext -Force`, `Connect-AzAccount`) and re-run, rather than just reporting timeout.

---

## [1.3.2] - 2026-05-15

### Fixed

- **`New-AzKeyVault -EnableRbacAuthorization` removal in Az.KeyVault 6.0+.** Microsoft made a breaking change in Az.KeyVault 6.0.0 (October 2025): RBAC is now the default for new vaults, `-EnableRbacAuthorization` was removed, and `-DisableRbacAuthorization` was added as the inverse opt-out switch. The script now inspects the cmdlet's parameter set at runtime and uses the appropriate flag — or no flag at all if RBAC is already the default. This is more robust than version-string parsing across preview builds and forks.

### Added

- **Legacy vault detection.** When `Initialize-KeyVaultAccess` finds an existing vault using legacy access policies (RBAC not enabled), the script now surfaces a clear warning explaining that its role-assignment approach won't work and offering two remediation paths: migrate the vault to RBAC, or add an access policy manually.

---

## [1.3.1] - 2026-05-15

### Fixed

- **`Get-AzVMSize -Location` deprecation.** `Az.Compute 10.0.1` (released June 2025) deprecated the `-Location` parameter set on `Get-AzVMSize` and now throws "A parameter cannot be found that matches parameter name 'Location'." The deploy script now uses `Get-AzComputeResourceSku` (Microsoft's recommended replacement) for region/size validation.
- **Region restriction detection.** When the new SKU query returns a size with regional restrictions (quota limits, zone restrictions), the script now surfaces this as a warning before attempting deployment, allowing the user to request quota increases proactively rather than waiting for the VM provisioning step to fail.
- **Cross-tenant token warning noise.** `Get-AzSubscription` emits warnings when it tries to authenticate to tenants requiring fresh MFA — these are not failures, just side effects of enumerating across all tenants the account has ever touched. Wrapped subscription-enumeration calls in `-WarningAction SilentlyContinue` across all four scripts to quiet this noise.

### Changed

- **Size verification is now non-blocking on lookup errors.** If the SKU query fails (network, permissions, transient API error), the script proceeds with a warning rather than aborting the deployment. The actual VM provisioning step will surface the real error if the size is truly unavailable.

---

## [1.3.0] - 2026-05-15

### Added

- **Key Vault RBAC auto-configuration.** When `Deploy-ERPNextToAzure.ps1` is invoked with `-UseKeyVault`, the script now automatically assigns the **Key Vault Secrets Officer** role to the running identity at vault scope, then polls the Key Vault data plane until RBAC propagation completes before attempting to write secrets. Previously, the first `Set-AzKeyVaultSecret` call would fail with 403 because creating an RBAC-enabled vault does not implicitly grant the creator data-plane permissions.
- **Principal type detection.** The script correctly resolves the AAD object ID for `User`, `ServicePrincipal`, and `ManagedService` (managed identity) account types — necessary because role assignments are made against object IDs, not UPNs.
- **Pre-existing vault detection.** If `-KeyVaultName` points to a vault that already exists, the script tests data-plane access before doing anything else. If access is already in place, no role assignment is attempted. This supports the common pattern where an Owner pre-provisions vaults for delegated teams.
- **Insufficient-permission diagnostics.** If the running identity lacks `Microsoft.Authorization/roleAssignments/write` (i.e., has only Contributor rather than Owner or User Access Administrator), the script detects this on role assignment failure and surfaces a clear remediation guide: have an Owner/UAA pre-grant access, pre-create the vault, or omit `-UseKeyVault`.
- **Retry-with-backoff** on the actual `Set-AzKeyVaultSecret` call as a final safety net in case RBAC propagation completes between the access probe and the first write.

### Changed

- **`Set-VMKeyVaultSecret` is now retry-aware** with exponential backoff on 403 errors.
- **`-UseKeyVault` parameter documentation** updated to specify the required Azure roles and the fallback path when permissions are insufficient.

---

## [1.2.1] - 2026-05-15

### Changed

- **Select-AzureContext.ps1 actionable errors.** When `-SearchName` or `-TenantId` finds no matches, the script now explains that the authenticated account has limited tenant visibility and shows the exact `Connect-AzAccount` commands needed to add another account or sign into a specific tenant. The previous "not found" error was technically correct but unhelpful — most failures of this kind are missing authentication, not missing resources.
- **Select-AzureContext.ps1 single-subscription hint.** When `-ListOnly` shows only one accessible subscription, the script now includes guidance on authenticating additional accounts. Common for consultants who've signed into a client account and forgotten to add their own.

---

## [1.2.0] - 2026-05-15

### Added

- **Multi-tenant / consultant workflow.** All scripts now have first-class support for accounts with access to multiple Azure tenants and subscriptions — common for IT consultants and MSP engineers.
- **`-TenantId` parameter** added to `Deploy-ERPNextToAzure.ps1` and `Remove-ERPNextAzureDeployment.ps1`. Switches to the specified Azure AD tenant before resolving subscription.
- **`-SelectContext` parameter** on both deploy and teardown — presents an interactive numbered picker listing all accessible subscriptions across all tenants the account can see.
- **`-ConfirmContext` safety gate** on `Deploy-ERPNextToAzure.ps1`. When the account has access to more than one subscription and neither `-SubscriptionId` nor `-SelectContext` is supplied, the deploy refuses to run unless `-ConfirmContext` is passed. Prevents silent deploys into the wrong client's tenant.
- **`Select-AzureContext.ps1`** — new standalone helper for switching Azure contexts. Supports listing all accessible subscriptions, interactive selection, search by partial name, direct GUID switching, and saving named contexts for fast restore.
- **Active context banner.** Every script now prints account, tenant, and subscription prominently before any resource operation, making wrong-context runs immediately visible.
- **`Select-AzureContext` shared function** replaces the previous `Test-AzureConnection` in both deploy and teardown scripts. Handles tenant switching, subscription switching, and optional interactive picking in one place.

---

## [1.1.1] - 2026-05-15

### Fixed

- **Remove-ERPNextAzureDeployment.ps1 `-WhatIf` noise** — `-WhatIf` was propagating into internal `Add-Content` log writes, producing spurious "What if: Performing the operation Add Content" lines on every log call. Log writes are now explicitly excluded from WhatIf with `-WhatIf:$false`.
- **Remove-ERPNextAzureDeployment.ps1 wrong-subscription diagnostics** — when the target Resource Group exists but lives in a different subscription than the active `Get-AzContext`, the script previously reported "not found" with no further guidance. It now searches across all accessible subscriptions and reports exactly which subscription contains the RG, with the precise `-SubscriptionId` command to re-run.
- **Remove-ERPNextAzureDeployment.ps1 teardown plan visibility** — the teardown plan header now shows the active Azure account and subscription before any action is taken, making wrong-context runs immediately obvious.

---

## [1.1.0] - 2026-05-15

### Added

- **`Remove-ERPNextAzureDeployment.ps1`** — new teardown script with two modes (whole Resource Group, or selective per-resource), resource-lock detection and optional removal, Key Vault soft-delete handling with optional purge to free the vault name immediately, local-artifact cleanup, production-subscription safety check, and full `-WhatIf`/`-Confirm` support.
- **End-to-end deployment** — `Deploy-ERPNextToAzure.ps1` now runs the ERPNext installation on the VM automatically via `Invoke-AzVMRunCommand`. The manual SCP/SSH step is no longer required.
- **Azure Key Vault integration** — `-UseKeyVault` and `-KeyVaultName` parameters store VM admin, MariaDB root, and ERPNext admin passwords as Key Vault secrets instead of writing them to a local JSON file.
- **SSH key authentication** — `-UseSSHKey` and `-SSHPublicKeyPath` parameters configure SSH key auth and disable password auth on the VM.
- **Source IP restriction** — `-AllowedSourceCIDR` parameter scopes NSG inbound rules to a specific IP or CIDR block.
- **Subscription targeting** — `-SubscriptionId` parameter switches the active Az context to a specific subscription before deploying.
- **Idempotency** — every Azure resource (Resource Group, NSG, Public IP, VNet, NIC, VM, Key Vault) is checked for existence before creation. Re-running after a partial failure is safe.
- **Pre-flight checks** — connection, subscription, resource providers, region/VM SKU availability are all validated before any resources are touched.
- **Structured logging** — both scripts write timestamped log files alongside their output.
- **Result object** — `Deploy-ERPNextToAzure.ps1` returns a `PSCustomObject` containing all deployment metadata, enabling pipeline use.
- **Cleanup guidance on failure** — when deployment fails, the script reports which Resource Group to remove for cleanup.
- **`-SkipInstall` parameter** — provisions infrastructure only; useful for debugging.
- **`-InstallTimeoutMinutes` parameter** — caps the install Run Command wait time.
- **`-ThrottleMilliseconds` parameter** (import script) — configurable API call throttling.
- **`-SkipSSLValidation` parameter** (import script) — for self-signed certificate environments.
- **Retry-on-transient-error** (import script) — exponential backoff for 5xx and 429 responses.
- **`Get-PropertyOrDefault` helper** (import script) — StrictMode-safe property access.
- **README.md** — GitHub project overview.
- **CHANGELOG.md** — this file.
- **Project tags** on the Resource Group for tracking.

### Changed

- **Node.js upgraded from 18 to 20 LTS.** Node 18 reached end-of-life April 2025.
- **wkhtmltopdf** download path corrected to the maintained `0.12.6.1-3` build; install uses `apt-get install -y` to resolve dependencies cleanly on Ubuntu 24.04.
- **Install script construction** rewritten as a PowerShell array joined with `"`n`"` to avoid here-string escaping pitfalls and ensure LF (not CRLF) line endings.
- **Password generation** now uses `System.Security.Cryptography.RandomNumberGenerator` instead of `Get-Random` for cryptographically strong randomness. Excludes visually ambiguous characters (`0`, `1`, `l`, `I`, `O`) and shell-hostile characters (`$`, `` ` ``, `'`, `"`, `&`).
- **MariaDB and ERPNext admin passwords** are now generated per-deployment instead of hardcoded.
- **`is_group` flag** (import script) now derived from actual presence of children in the imported dataset, not a depth heuristic. Categories with zero children become leaf groups regardless of nesting level.
- **404 exception handling** (import script) updated for PowerShell 7's `HttpResponseException` (different shape than 5.1's `WebException`).
- **Parameter validation** added to all parameters: regex patterns for VM names, usernames, CIDR blocks, URLs; range validation for disk size and timeouts.
- **`SupportsShouldProcess`** added to both scripts — `-WhatIf` and `-Confirm` are now supported on destructive operations.
- **Default ERPNext username** in documentation corrected from `JTCAdmin` to `Administrator` (the ERPNext default).
- **VM size in cost estimates** corrected from `Standard_D2s_v3` to `Standard_D2s_v6` to match the actual script default.
- **Quick Start Guide** rewritten to reflect the new end-to-end flow.

### Fixed

- **CRLF line endings** in the generated install script — bash on Linux rejects CRLF. Now explicitly written with UTF-8 (no BOM) and LF endings via `[System.IO.File]::WriteAllText`.
- **MariaDB secure-installation commands** no longer reference the post-password `mysql` invocation without authenticating — subsequent statements now use `mysql -u root -p"${MARIADB_ROOT_PW}"`.
- **StrictMode-safe property access** throughout the import script — previously, `$category.parent` on rows missing the column would throw under `Set-StrictMode -Version Latest`.
- **Trailing slash** on `-ERPNextURL` is now trimmed automatically to prevent doubled slashes in API endpoint paths.
- **API authentication header** generation handles empty or whitespace-padded keys consistently.

### Security

- Default plaintext credentials removed from the generated install script. All credentials are now generated per-deployment.
- Resource Group tagged with creator metadata for auditability.
- Boot diagnostics deliberately disabled by default to avoid creating an additional storage account requiring separate hardening.

---

## [1.0.0] - 2026-02-17

### Added

- Initial release of `Deploy-ERPNextToAzure.ps1`:
  - Azure VM provisioning on Ubuntu 24.04 LTS
  - ERPNext installation bash script generation (manual execution)
  - Network Security Group with rules for ports 22, 80, 443, 8000
  - Static Public IP assignment
  - Premium SSD managed disk
  - JSON connection info file output
- Initial release of `Import-ERPNextCategories.ps1`:
  - WooCommerce category Excel parsing via `ImportExcel`
  - REST API-based Item Group creation in ERPNext
  - Parent-child relationship preservation
  - Dry-run mode
  - Progress reporting and basic error handling
- `WooCommerce-Integration-Guide.md` — full integration reference
- `Data-Structure-Plan.md` — data migration plan
- `Quick-Start-Guide.md` — step-by-step walkthrough

---

[1.6.5]: https://github.com/JONeillSr/erpnext-azure/compare/v1.6.4...v1.6.5
[1.6.4]: https://github.com/JONeillSr/erpnext-azure/compare/v1.6.3...v1.6.4
[1.6.3]: https://github.com/JONeillSr/erpnext-azure/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/JONeillSr/erpnext-azure/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.6...v1.6.0
[1.5.6]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.5...v1.5.6
[1.5.5]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.7...v1.5.0
[1.4.7]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.6...v1.4.7
[1.4.6]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.5...v1.4.6
[1.4.5]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.8...v1.4.0
[1.3.8]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.7...v1.3.8
[1.3.7]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.6...v1.3.7
[1.3.6]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.5...v1.3.6
[1.3.5]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.4...v1.3.5
[1.3.4]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/JONeillSr/erpnext-azure/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/JONeillSr/erpnext-azure/releases/tag/v1.0.0
