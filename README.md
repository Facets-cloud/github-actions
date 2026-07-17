# Facets GitHub Actions

Actions in this repo are consumed as `Facets-cloud/github-actions/<action>@<version>`.
Releases are semver tags with a moving major alias (`v1` always points at the latest
`v1.x.y`) — pin the major alias unless you need an exact version.

## 1. Facets Module CI (current)

The **Facets Module CI** GitHub Action provides end-to-end CI for a Facets **modules
repository** (`modules/{intent}/{flavor}/{version}`) using the **`raptor`** CLI. It runs
in three modes, derived automatically from the triggering event:

[module-ci-action README](./module-ci-action/README.md).

- **Preview (on pull request)**: Validates each changed module, then registers an
  unpublishable feature-branch preview pinned to the PR head commit (optionally posts a
  PR comment).
- **Publish (on push)**: Uploads and publishes each changed module (PREVIEW → PUBLISHED).
- **Cleanup (on pull request close)**: Deletes each changed module's preview, but only
  the previews this PR's own commits created (ownership-checked).

This is the action the Facets control plane wires into bootstrapped modules
repositories, and the recommended CI for all modules repos.

## 2. Facets Module Preview & Security Scan (deprecated)

> ⚠️ **Deprecated.** This action is based on the legacy `ftf` CLI and is kept only for
> existing workflows that still use it. It receives no new features. New repos should
> use [**module-ci-action**](./module-ci-action/README.md) above; to migrate, replace
> the `module-preview-action` step with `module-ci-action` (raptor-based inputs — see
> its README) and adopt the `modules/{intent}/{flavor}/{version}` layout.

The **Facets Module Preview & Security Scan** GitHub Action automates validation and
security checks for Facets Terraform modules:

[module-preview-action README](./module-preview-action/README.md).

- **Terraform Formatting Checks**: Ensures Terraform files are formatted correctly.
- **Terraform Validation**: Verifies the correctness of Terraform configurations.
- **Checkov Security Scanning**: Identifies security vulnerabilities in Terraform code.
- **Facets Module Preview**: Registers a Preview only module with your Facets Control Plane.
