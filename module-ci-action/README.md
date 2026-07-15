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
| `pull_request` **closed** | **cleanup** | Deletes the preview each changed module owns — **only if** the preview belongs to a commit from this PR. |

> This action is a sibling of [`module-preview-action`](../module-preview-action)
> (the `ftf`-based action). They are independent — pick the one that matches your CLI.

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

- **Runner:** Ubuntu (the action installs a Linux amd64 `raptor` binary).
- **raptor version:** preview and cleanup depend on newer `raptor` capabilities:
  - **preview** uses `raptor create iac-module --feature-branch`, a flag that marks a
    preview as **unpublishable**.
  - **cleanup** reads module git provenance (`gitRef` / `previewGitRef`) from
    `raptor get iac-module -o json` for its ownership check, and deletes with
    `raptor delete iac-module --stage PREVIEW`, which targets **only** the preview doc
    (so a module that has both a published and a preview version never loses its live
    published doc).

  These require a `raptor` release that ships all three (`--feature-branch`, row-level
  provenance in the list JSON, and `delete --stage`). Pin `raptor_version` if `latest`
  ever lags. Publish works on any recent `raptor`; cleanup safely no-ops when the
  provenance fields are absent.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `control_plane_url` | yes | — | Facets Control Plane URL. Pass the `CONTROL_PLANE_URL` secret. |
| `username` | yes | — | Facets username. Pass the `FACETS_USERNAME` secret. |
| `token` | yes | — | Facets API token. Pass the `FACETS_TOKEN` secret. |
| `github_token` | no | `""` | GitHub token. Enables the PR **preview comment** and, in **cleanup**, reading the PR's commit SHAs for the ownership check. When absent, those are skipped (cleanup does nothing, safely). |
| `raptor_version` | no | `latest` | `latest`, or an exact release tag such as `v1.2.3`. |
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
        uses: Facets-cloud/github-actions/module-ci-action@master
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

## Single-preview-slot semantics

Each module (`intent/flavor/version`) has exactly **one preview slot** on the Control
Plane. When a PR previews a module, the action registers the preview against the PR's
**head commit** (`--git-ref`), so the slot records which commit owns it.

- **Concurrent PRs on the same module:** last write wins. Whichever PR most recently
  ran preview owns the slot; an earlier PR's preview is overwritten.
- **Cleanup is ownership-checked.** On PR close, the action reads each module's owning
  commit from `raptor get iac-module -o json` and deletes the preview **only if** that
  commit is one of this PR's commit SHAs. If the slot was taken over by another branch,
  this PR leaves it untouched — it never deletes a preview owned by someone else.
  (Cleanup needs `github_token` to read the PR's commits; without it, cleanup is skipped.)

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
