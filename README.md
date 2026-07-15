# Facets GitHub Actions


## 1. Facets Module Preview & Security Scan

The **Facets Module Preview & Security Scan** GitHub Action automates validation and security checks for Facets
Terraform modules. It performs the following tasks:

[module-preview-action README](./module-preview-action/README.md).

- **Terraform Formatting Checks**: Ensures Terraform files are formatted correctly.
- **Terraform Validation**: Verifies the correctness of Terraform configurations.
- **Checkov Security Scanning**: Identifies security vulnerabilities in Terraform code.
- **Facets Module Preview**: Registers a Preview only module with your Facets Control Plane.

## 2. Facets Module CI

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

This action is a sibling of the `ftf`-based `module-preview-action` above and does not
replace it — choose the one matching your CLI.

