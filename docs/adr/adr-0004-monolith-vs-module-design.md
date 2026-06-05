---
title: "ADR-0004: Single-File Monolith vs. Multi-Module Script Architecture"
status: "Accepted"
date: "2026-06-05"
authors: "Migration Script Architect"
tags: ["architecture", "decision", "structure", "modularity", "deployment"]
supersedes: ""
superseded_by: ""
---

# ADR-0004: Single-File Monolith vs. Multi-Module Script Architecture

## Status

Proposed | **Accepted** | Rejected | Superseded | Deprecated

## Context

The migration workflow spans approximately 2,400 lines of PowerShell 7 across distinct functional domains:

- **vCenter / PowerCLI operations**: VM discovery, snapshot management, VMDK hot-attach/detach, vMotion
- **Offline disk operations**: Disk mounting, Windows partition detection, VirtIO driver injection via DISM, registry hive manipulation
- **Morpheus REST API**: Authentication, migration plan lifecycle, instance polling, agent task execution
- **WinRM operations**: Remote execution, VMware Tools removal, Morpheus agent installation
- **Interactive parameter resolution**: Numbered menus for VM, cloud, pool, network, datastore selection

Each domain is logically self-contained. Standard software engineering practice would suggest decomposing these into separate `.psm1` modules or at minimum separate `.ps1` files that are dot-sourced.

The primary deployment scenario is: a Windows management host or jump box, potentially air-gapped, where an operator downloads and runs the script. The tool must be runnable with minimal prerequisites.

## Decision

**Maintain a single-file monolith** (`Invoke-VMwareWindowsMigrationToVME.ps1`) containing all functions. Do not decompose into `Import-Module` dependencies or dot-sourced sub-scripts.

The single file contains:
1. `param()` block with all 30+ parameters
2. `Set-StrictMode` / `$ErrorActionPreference` immediately after `param()`
3. All helper functions in dependency order (callees before callers)
4. Main execution block at the end

Functions are grouped logically within the file and documented in AGENTS.md with approximate line numbers.

## Consequences

### Positive

- **POS-001**: **Zero deployment friction** — operators copy one file to any Windows management host and execute. No `Install-Module`, no `Import-Module`, no directory structure to replicate, no `$PSModulePath` configuration.
- **POS-002**: **Air-gap friendly** — the script runs in isolated environments without internet access or a PowerShell Gallery mirror. The only external dependency is VCF.PowerCLI, which is explicitly documented and checked at startup.
- **POS-003**: **Self-contained troubleshooting** — the entire execution context (parameters, functions, state) is visible in one file. Operators and support staff can `Ctrl+F` for any function name without navigating a module hierarchy.
- **POS-004**: **No module versioning complexity** — there is no risk of a function from module v1.2 being called by a script expecting module v1.3 semantics. A single file is always internally consistent.
- **POS-005**: **Parse validation is trivial** — a single `[System.Management.Automation.Language.Parser]::ParseFile` call validates the entire codebase.

### Negative

- **NEG-001**: The file is ~2,400 lines. Functions in the same domain are not physically co-located in separate files, making large-scale refactoring harder.
- **NEG-002**: No `Export-ModuleMember` surface — all functions are technically callable by any caller once the script is dot-sourced, though in practice the script is only ever invoked as a standalone executable.
- **NEG-003**: Pester unit tests cannot easily import individual functions in isolation without dot-sourcing the entire script (which executes the main block). A module design would allow `Import-Module` + targeted function testing.
- **NEG-004**: As the script grows (new OS support, new cloud targets), the single file will become harder to navigate. The current structure has no enforced module boundaries to prevent domain coupling.

## Alternatives Considered

### Multi-Module Architecture (`psm1` files per domain)

- **ALT-001**: **Description**: Split into `VirtIO-VCenter.psm1`, `VirtIO-OfflineDisk.psm1`, `VirtIO-Morpheus.psm1`, `VirtIO-WinRM.psm1`, and a thin orchestrator script. Each module is independently testable and versioned.
- **ALT-002**: **Rejection Reason**: Deployment complexity increases significantly — the operator must deploy a directory tree and ensure `$PSModulePath` is correct. An air-gapped environment without PowerShell Gallery requires manual staging of all module files. The operational benefit (isolation, unit testing) does not outweigh the deployment friction for the target audience (migration engineers running one-off migrations from jump boxes).

### Dot-Sourced Sub-Scripts

- **ALT-003**: **Description**: Keep a thin `Invoke-VMwareWindowsMigrationToVME.ps1` orchestrator that dot-sources domain files: `. .\lib\OfflineDisk.ps1`, `. .\lib\MorpheusApi.ps1`, etc.
- **ALT-004**: **Rejection Reason**: Introduces relative path dependency — the operator must run the script from a specific working directory or set `$PSScriptRoot`-relative paths correctly. Copying just the main `.ps1` file (as operators often do) would silently break all domain functions. This is a worse deployment experience than the monolith without the testability advantages of a proper module.

### Script Classes (`class` keyword in PS5+)

- **ALT-005**: **Description**: Encapsulate domain logic into PS classes (`class MorpheusClient`, `class VirtIOInjector`) within the same file to provide namespace separation without deployment complexity.
- **ALT-006**: **Rejection Reason**: PowerShell class syntax has well-documented limitations: class methods cannot use pipeline input natively, error handling via `$ErrorActionPreference = 'Stop'` behaves differently inside class methods, and class definitions are not reloadable in the same session without module unloading. The function-based approach is more idiomatic for PowerShell infrastructure scripts and better understood by the operations audience.

## Implementation Notes

- **IMP-001**: Function order within the file follows dependency order — functions that call other functions are defined below their callees. This is required for PowerShell's single-pass function resolution at runtime.
- **IMP-002**: The `$script:` scope qualifier is used for variables that `Resolve-MorpheusTargetParameters` and `Resolve-VCenterTargetParameters` must write back to the outer execution scope. Each such assignment is annotated with `# script scope: must mutate across function boundaries`.
- **IMP-003**: The shared VMware Tools removal script is stored in `$script:VmtRemovalScript` (a script-scope variable holding a here-string) to eliminate duplication between `Remove-VMwareToolsViaTask` and `Remove-VMwareToolsViaWinRM`. This is the only intentional use of script-scope state for code sharing (as opposed to parameter passing).
- **IMP-004**: If the codebase grows beyond ~4,000 lines or gains a second orchestrator script, revisit this decision. At that scale, the dot-sourced sub-scripts approach (ALT-003) becomes viable if `$PSScriptRoot`-relative paths are used consistently throughout.
- **IMP-005**: Pester testing of individual functions is possible by dot-sourcing the script with a mock `param()` override or by extracting function bodies into a test harness. See CONTRIBUTING.md for the recommended parse-check and dry-run validation process.

## References

- **REF-001**: AGENTS.md — Script Structure table (line number regions)
- **REF-002**: CONTRIBUTING.md — Testing Your Changes
- **REF-003**: ADR-0003 — SecureString credential routing (`$script:` scope for credential state)
- **REF-004**: [PowerShell Best Practices and Style Guide — Module Design](https://poshcode.gitbook.io/powershell-practice-and-style/style-guide/function-structure)
