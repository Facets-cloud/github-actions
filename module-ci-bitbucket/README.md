# Facets Module CI — Bitbucket Pipelines glue

The Bitbucket counterpart of [`module-ci-action`](../module-ci-action/README.md) (GitHub) and
[`module-ci-gitlab`](../module-ci-gitlab/README.md) (GitLab). It runs the **same** shared
[`module-ci-core.sh`](../module-ci-core.sh) the other hosts run, so the three never drift — this
is only the thin Bitbucket glue: resolve the mode, map Bitbucket's predefined variables to the
generic `MC_*` contract, fetch + run the core, and post the pull-request preview comment.

## Why a script, not an include

GitLab consumes its template as a remote `include:`. **Bitbucket Pipelines has no remote
include**, so a modules repo's `bitbucket-pipelines.yml` can't pull a hosted template. It instead
`curl`s [`run.sh`](./run.sh) (pinned to a tag) and runs it — the control plane wires that in at
bootstrap, the same way it wires `module-ci-action@v1` (GitHub) or the GitLab include. The glue is
still centrally versioned here; only the thin fetch-and-run lives in the repo.

```yaml
# bitbucket-pipelines.yml (what the control plane pushes into the repo)
script:
  - curl -fsSL "https://raw.githubusercontent.com/Facets-cloud/github-actions/v1/module-ci-bitbucket/run.sh" -o /tmp/run.sh
  - bash /tmp/run.sh
```

## Modes

- **Preview (on pull request)**: creates each changed output type the control plane does not have
  yet, validates each changed module, and registers an unpublishable feature-branch preview pinned
  to the source commit. Posts a PR comment when `FACETS_PR_TOKEN` is set.
- **Publish (on default-branch push)**: applies each changed output type, then uploads and
  publishes each changed module (PREVIEW → PUBLISHED), declaring compatible-update vs
  version-upgrade from what the registry already holds.

Output types are always applied **before** any module — a module names its output type by
reference, and the control plane refuses a module whose type it does not already hold.

## Variables

| Variable | Required | Meaning |
|---|---|---|
| `CONTROL_PLANE_URL` | yes | Facets Control Plane URL |
| `FACETS_USERNAME` | yes | Facets username |
| `FACETS_TOKEN` | yes | Facets API token |
| `FACETS_PATH_PREFIX` | no | sub-path to `modules/` (default `""`: repo root) |
| `FACETS_MODULE_CI_REF` | no | `github-actions` ref the core + glue are fetched from (default `v1`) |
| `FACETS_PR_TOKEN` | no | a Bitbucket access token that can write PR comments; enables the preview comment |

The control-plane bootstrap provisions the three required variables as secured pipeline variables.

## Not yet supported

**Cleanup-on-close.** Bitbucket runs no pipeline when a pull request is closed, so deleting a
closed PR's preview needs a separate trigger (a webhook or a scheduled sweep). The core already
implements `cleanup` (ownership-checked); only the Bitbucket trigger is missing. Tracked as a
follow-up — the same gap GitLab has.
