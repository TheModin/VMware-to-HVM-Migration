---
title: "ADR-0003: SecureString Credential Routing and [object]-Typed VM Password Parameters"
status: "Accepted"
date: "2026-06-05"
authors: "Migration Script Architect"
tags: ["architecture", "decision", "security", "credentials", "securestring"]
supersedes: ""
superseded_by: ""
---

# ADR-0003: SecureString Credential Routing and [object]-Typed VM Password Parameters

## Status

Proposed | **Accepted** | Rejected | Superseded | Deprecated

## Context

The script handles multiple categories of credentials:

1. **VM credentials** (`HelperVMPassword`, `TargetVMPassword`) — used to construct `PSCredential` objects for WinRM sessions and `Invoke-VMScript` calls.
2. **Morpheus API credentials** (`MorpheusToken`, `MorpheusPassword`) — used to obtain or pass a Morpheus bearer token; the token is decrypted only at the moment of HTTP use.
3. **vCenter credentials** (`VCPassword`) — passed to `Connect-VIServer` to authenticate against the vCenter API.

Two design tensions exist:

**Tension 1 — Usability vs security for VM passwords**: If `HelperVMPassword` and `TargetVMPassword` are typed `[System.Security.SecureString]`, PowerShell rejects plain string literals at parameter binding time. This forces operators to wrap every password in `ConvertTo-SecureString "..." -AsPlainText -Force` at the call site, which is verbose and error-prone. However, if they are typed `[string]`, the password lives as plaintext in memory and process inspection tools.

**Tension 2 — API token lifetime**: The Morpheus bearer token (or password used to obtain one) must never appear in log output, error messages, or process arguments. It must be decrypted only for the duration of a single HTTP Authorization header construction and the BSTR pointer zeroed immediately after.

These two tensions require different handling strategies. A single approach cannot satisfy both.

## Decision

Apply a **two-tier credential routing strategy**:

**Tier 1 — VM passwords (`[object]` typed with `ConvertTo-SecurePassword`)**:
- `HelperVMPassword` and `TargetVMPassword` are declared as `[object]` in the `param()` block.
- Immediately after the `param()` block, both are passed through `ConvertTo-SecurePassword`, which accepts `string`, `SecureString`, or `PSCredential` and always returns a `SecureString`.
- This allows operators to pass plain strings for convenience while ensuring the value is secured in memory before any function receives it.
- `ConvertTo-SecurePassword` throws a typed error for unsupported input types.

**Tier 2 — API credentials (`[System.SecureString]` typed, BSTR-zero pattern)**:
- `MorpheusToken`, `MorpheusPassword`, and `VCPassword` are declared as `[System.Security.SecureString]` in the `param()` block.
- Callers **must** pass these as `SecureString` (e.g. `ConvertTo-SecureString "token" -AsPlainText -Force`).
- In `Get-MorpheusAuthHeaders`, the token/password is decrypted using `Marshal.SecureStringToBSTR`, the plaintext string is used to construct the Authorization header string, and `Marshal.ZeroFreeBSTR` is called in a `finally` block to zero the unmanaged BSTR copy.
- The plaintext variable is removed with `Remove-Variable` immediately after use.

## Consequences

### Positive

- **POS-001**: VM passwords can be passed as plain strings in interactive/pipeline usage without requiring `ConvertTo-SecureString` at the call site, reducing operator friction during initial testing.
- **POS-002**: API tokens are never stored as plain strings in managed memory; BSTR zeroing ensures the plaintext token cannot be recovered from a memory dump after the HTTP call completes.
- **POS-003**: `ConvertTo-SecurePassword` provides a single, tested conversion path — any future credential type additions only need to extend one function.
- **POS-004**: Type enforcement at parameter binding for `MorpheusToken`/`MorpheusPassword` prevents accidental plain-string API token passing which would be silently accepted but represent a security regression.

### Negative

- **NEG-001**: The `[object]` typing for VM passwords means PowerShell's tab-completion and help system cannot infer the expected type — operators must consult documentation to know what is accepted.
- **NEG-002**: Two different credential-handling patterns exist in the same codebase. Contributors must consult AGENTS.md to know which pattern applies to which parameter, creating cognitive overhead.
- **NEG-003**: `ConvertTo-SecureString -AsPlainText -Force` (required for Tier 2) still temporarily creates a plain string in managed memory before conversion. Full in-memory security requires credential input via `Read-Host -AsSecureString` or a secrets vault.
- **NEG-004**: BSTR zeroing is a .NET interop detail. If a future PS version changes the `Marshal` API behavior, the zeroing pattern would need re-evaluation.

## Alternatives Considered

### All Parameters Typed `[System.Security.SecureString]`

- **ALT-001**: **Description**: Declare all password parameters as `[System.Security.SecureString]`. Operators always pass `(ConvertTo-SecureString "..." -AsPlainText -Force)`.
- **ALT-002**: **Rejection Reason**: Severely degrades usability for the VM credential parameters used in the most common interactive invocation pattern. Error messages for type mismatches at binding time are not user-friendly. The Morpheus API credentials warrant this strictness (they are API secrets); the VM credentials are operational convenience parameters where the trade-off favors usability.

### All Parameters Typed `[string]` with Immediate In-Function Conversion

- **ALT-003**: **Description**: Accept all passwords as plain strings and convert to `SecureString` inside each function that uses them.
- **ALT-004**: **Rejection Reason**: Plain strings persist in memory across all function calls between parameter binding and first use. PowerShell's `$args` and history mechanisms can capture them. API tokens as plain strings are particularly high-risk since they could appear in `$PSBoundParameters` logging or `-Verbose` output.

### Use a Secrets Vault (e.g. SecretManagement module)

- **ALT-005**: **Description**: Require all credentials to be stored in a PSSecretManagement-compatible vault (e.g. Windows Credential Manager, HashiCorp Vault). Parameters accept vault key names instead of values.
- **ALT-006**: **Rejection Reason**: Introduces a mandatory external dependency that may not be available in all deployment environments (air-gapped labs, minimal management hosts). Adds significant complexity to the invocation pattern for a single-script tool. Appropriate for a long-term hardening initiative but out of scope for the current design goals.

## Implementation Notes

- **IMP-001**: `ConvertTo-SecurePassword` is defined at line ~151, immediately after `Set-StrictMode`. It is called for `HelperVMPassword` and `TargetVMPassword` at lines ~164–165.
- **IMP-002**: The BSTR-zero pattern in `Get-MorpheusAuthHeaders` (line ~864): `SecureStringToBSTR` → `PtrToStringAuto` in try block → `ZeroFreeBSTR` in finally block → `Remove-Variable morpheusPasswordPlain`.
- **IMP-003**: `VCPassword` is passed directly to `Connect-VIServer -Password` as a `SecureString`. PowerCLI's `Connect-VIServer` natively accepts `SecureString` for its `-Password` parameter.
- **IMP-004**: When extending the script with new credential parameters, consult AGENTS.md §Password handling to determine which tier applies: use `[object]` + `ConvertTo-SecurePassword` for VM/OS credentials; use `[System.Security.SecureString]` + BSTR-zero for API tokens and secrets.

## References

- **REF-001**: `ConvertTo-SecurePassword` function (line ~151)
- **REF-002**: `Get-MorpheusAuthHeaders` function, BSTR-zero pattern (line ~864)
- **REF-003**: AGENTS.md — Password handling convention
- **REF-004**: [.NET Marshal.ZeroFreeBSTR documentation](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.interopservices.marshal.zerofreebstr)
- **REF-005**: [OWASP Secure Coding Practices — Credential Management](https://owasp.org/www-project-secure-coding-practices-quick-reference-guide/)
