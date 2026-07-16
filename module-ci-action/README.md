# Facets Module CI GitHub Action

CI for a **Facets modules repository** — a repo whose Terraform IaC modules follow
the Facets layout and are managed through the [`raptor`](https://github.com/Facets-cloud/raptor-releases)
CLI (not `ftf`, not Python).

The action runs in one of three **modes**, normally derived automatically from the
triggering event:

| Event | Mode | What it does |
|-------|------|--------------|
| `pull_request` opened / synchronize / reopened | **preview** | Validates each changed module, then registers a **feature-branch preview** pinned to the PR head commit. Optionally upserts a PR comment. |
| `push` (to your default branch) | **publish** | Uploads each changed module and **publishes** it (PREVIEW → PUBLISHED). |
| `pull_request` **closed without merge** | **cleanup** | Deletes the preview each changed module owns — **only if** the preview belongs to a commit from this PR. |
| `pull_request` **closed by merge** | **no-op** | Skipped: the concurrent `push` (publish) run re-uploads and publishes the module at the merge commit, so it owns the slot. Running cleanup here would be redundant and could race the publish. |

> This action supersedes the **deprecated** `ftf`-based
> [`module-preview-action`](../module-preview-action), which is kept only for
> existing workflows.

## Modules-repo layout

Each module lives at a versioned path and contains a `facets.yaml` plus its Terraform:

```
modules/
  <intent>/
    <flavor>/
      <version>/
        facets.yaml         # intent:, flavor:, version: (+ inputs/outputs/spec)
        main.tf
        variables.tf
        outputs.tf
```

The action discovers a module as **any directory under `modules/` that contains a
`facets.yaml`**. `intent`, `flavor`, and `version` are read from that `facets.yaml`
and form the module reference `intent/flavor/version` used by `raptor`.

If your modules tree is not at the repo root, set `path-prefix` (e.g. `infra/` when
modules live at `infra/modules/...`).

## Requirements

- **Runner:** Ubuntu (the action installs Linux amd64 `raptor`, and — for preview/publish
  — `terraform` and `trivy`, which raptor's module validation and security scan require;
  ubuntu-latest ships none of them). Versions are pinnable via the inputs below.
- **raptor version:** preview and cleanup depend on newer `raptor` capabilities:
  - **preview** uses `raptor create iac-module --feature-branch --git-ref <sha>` — the
    `--feature-branch` flag marks the preview **unpublishable**, and `--git-ref` pins it
    to the PR head commit (required, since the PR checkout is a merge commit). Both must
    be present in the `raptor` release you install.
  - **cleanup** reads module git provenance (`gitRef` / `previewGitRef`) from
    `raptor get iac-module -o json` for its ownership check, and deletes with
    `raptor delete iac-module --stage PREVIEW`, which targets **only** the preview doc
    (so a module that has both a published and a preview version never loses its live
    published doc).

  These require a `raptor` release that ships all of them (`--feature-branch`, `--git-ref`,
  row-level provenance in the list JSON, and `delete --stage`). Pin `raptor_version` if
  `latest` ever lags. Publish works on any recent `raptor`; cleanup safely no-ops when the
  provenance fields are absent.
- **Trigger:** use `pull_request` (not `pull_request_target`). `pull_request_target`
  checks out the base ref, which would produce an empty changed-file diff and incorrect
  git provenance; the action rejects it with an explicit error.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `control_plane_url` | yes | — | Facets Control Plane URL. Pass the `CONTROL_PLANE_URL` secret. |
| `username` | yes | — | Facets username. Pass the `FACETS_USERNAME` secret. |
| `token` | yes | — | Facets API token. Pass the `FACETS_TOKEN` secret. |
| `github_token` | no | `""` | GitHub token. Enables the PR **preview comment** and, in **cleanup**, reading the PR's commit SHAs for the ownership check. When absent, those are skipped (cleanup does nothing, safely). |
| `raptor_version` | no | `latest` | `latest`, or an exact release tag such as `v1.2.3`. Ignored when `raptor-download-url` is set. |
| `raptor-download-url` | no | `""` | Exact URL to download the raptor `linux-amd64` binary from, bypassing the default `Facets-cloud/raptor-releases` location. When set, `raptor_version` is ignored. An escape hatch for testing / pre-release raptor builds and enterprise mirrors. |
| `terraform-version` | no | `1.5.7` | Terraform version installed (from `releases.hashicorp.com`) for raptor's module validation. Not installed in **cleanup** mode. |
| `trivy-version` | no | `0.72.0` | Trivy version installed (from `aquasecurity/trivy` releases, no `v` prefix) for raptor's module security scan. Not installed in **cleanup** mode. |
| `all-modules` | no | `false` | When `true`, operate on **every** module under `<path-prefix>modules/` instead of only the ones the event changed. |
| `mode` | no | `auto` | `auto` \| `preview` \| `publish` \| `cleanup`. `auto` derives the mode from the event (see the table above). Set explicitly to override. |
| `path-prefix` | no | `""` | Sub-path to the `modules/` tree relative to the repo root (e.g. `infra/`). Empty means `modules/` is at the root. |

### Secrets

These three secrets are exactly what the Control Plane bootstrap provisions for a
modules repo. They are exported as the environment variables `raptor` reads directly
(its highest-priority auth — there is no non-interactive `raptor login`):

| Secret | Env var | Purpose |
|--------|---------|---------|
| `CONTROL_PLANE_URL` | `CONTROL_PLANE_URL` | Control Plane base URL |
| `FACETS_USERNAME` | `FACETS_USERNAME` | Username |
| `FACETS_TOKEN` | `FACETS_TOKEN` | API token |

## Example workflow

A single workflow wiring up all three triggers:

```yaml
name: Facets Module CI

on:
  pull_request:
    paths:
      - 'modules/**'
    types: [opened, synchronize, reopened, closed]   # closed drives cleanup
  push:
    branches: [main]
    paths:
      - 'modules/**'

permissions:
  contents: read
  pull-requests: write   # for the preview comment

jobs:
  module-ci:
    runs-on: ubuntu-latest
    steps:
      - name: Facets Module CI
        uses: Facets-cloud/github-actions/module-ci-action@v1
        with:
          control_plane_url: ${{ secrets.CONTROL_PLANE_URL }}
          username: ${{ secrets.FACETS_USERNAME }}
          token: ${{ secrets.FACETS_TOKEN }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          # raptor_version: v1.2.3   # pin if 'latest' lags the --feature-branch flag
          # path-prefix: infra/      # if modules live at infra/modules/...
```

If you prefer separate workflow files, split the three triggers apart and let `mode`
stay `auto`; the action derives `preview` / `publish` / `cleanup` from each event.

## Versioning

Reference this action by version, not by branch:

- **`@v1`** — the moving major alias; always points at the latest `v1.x.y` release.
  This is what the control plane's bootstrapped workflow uses and the right default.
- **`@v1.2.3`** — an exact release, if you need to pin harder.

Releases are cut by pushing a semver tag (`git tag v1.2.0 && git push origin v1.2.0`);
the repo's `release.yml` workflow then moves the major alias and publishes the GitHub
release. Breaking changes to the action's inputs or behavior get a new major
(`v2`, with a `v2` alias) — the `v1` alias never picks them up.

## Single-preview-slot semantics

Each module (`intent/flavor/version`) has exactly **one preview slot** on the Control
Plane. When a PR previews a module, the action registers the preview against the PR's
**head commit** (`--git-ref`), so the slot records which commit owns it.

- **Concurrent PRs on the same module:** last write wins. Whichever PR most recently
  ran preview owns the slot; an earlier PR's preview is overwritten.
- **Merged PRs skip cleanup.** When a PR is closed **by merging**, the concurrent `push`
  run publishes the module at the merge commit and owns the slot, so cleanup is skipped
  entirely (it would be redundant and could race the publish). Cleanup runs only for PRs
  **closed without merging** (abandoned PRs), where the preview would otherwise be orphaned.
- **Cleanup is ownership-checked.** On such a close, the action reads each module's owning
  commit from `raptor get iac-module -o json` and deletes the preview **only if** that
  commit is one of this PR's commit SHAs. If the slot was taken over by another branch,
  this PR leaves it untouched — it never deletes a preview owned by someone else.
  (Cleanup needs `github_token` to read the PR's commits; without it, cleanup is skipped.)
  Immediately before deleting, the action re-fetches the module and re-verifies the owning
  commit still matches, so a slot overwritten between the initial check and the delete is
  skipped. This narrows but does not fully eliminate the window: a **residual race**
  remains between that final re-verify and the delete call itself, so in a rare
  interleaving a preview another branch published in that instant could still be removed.

  The owning-commit field depends on the module's stage, because the Control Plane
  stores preview provenance in two different places:

  - a **brand-new, never-published** module *is* its own preview (stage `PREVIEW`) —
    its owning commit is the row's plain `gitRef`. This is the common PR case.
  - a **published** module that also has a live preview sibling (its `previewModuleId`
    is set) exposes the preview's commit as `previewGitRef` on the `PUBLISHED` row.
  - anything else has no preview slot, so cleanup skips it.

  Reading only `previewGitRef` would miss every brand-new-module preview (where it is
  null), so the ownership check consults `gitRef` or `previewGitRef` by stage.

## Behavior details

- **Which modules:** by default only the modules changed by the event (PR: `base..HEAD`;
  push: `before..after`, with an all-zeros `before` falling back to the pushed commit).
  Set `all-modules: true` to process the whole tree.
- **Validation gate (preview):** each module is first run through
  `raptor create iac-module -f <dir> --dry-run` (schema + Terraform + security checks)
  before the feature-branch registration.
- **Provenance:** preview passes the PR head SHA explicitly because the PR checkout is a
  merge commit; publish relies on auto-detected provenance (on a push the checked-out
  `HEAD` *is* the pushed commit). The git remote URL is auto-detected from the work tree.
- **Failure handling:** the action keeps going across modules and prints a summary of
  which passed and which failed, then **exits non-zero** if any module's validate /
  upload / publish / delete failed.
