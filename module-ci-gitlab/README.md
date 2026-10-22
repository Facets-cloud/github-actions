# Facets Module CI — GitLab CI template

The GitLab counterpart of [`module-ci-action`](../module-ci-action/README.md). It runs
the **same** shared [`module-ci-core.sh`](../module-ci-core.sh) the GitHub action runs, so
the two hosts never drift — this template is only the thin GitLab glue (resolve mode, map
GitLab's CI variables to the generic `MC_*` contract, fetch + run the core, post the
merge-request preview note).

Consumed as a remote include, pinned to a tag (the moving `v1` alias tracks the latest
`v1.x.y`, same convention as the actions):

```yaml
include:
  - remote: "https://raw.githubusercontent.com/Facets-cloud/github-actions/v1/module-ci-gitlab/template.gitlab-ci.yml"
```

The control plane wires this into a bootstrapped GitLab modules repo, the same way it wires
`module-ci-action@v1` into a GitHub one.

## Modes

- **Preview (on merge request)**: creates each changed output type the control plane does
  not have yet, validates each changed module, and registers an unpublishable feature-branch
  preview pinned to the source commit. Posts a merge-request note when `FACETS_MR_TOKEN` is set.
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
| `FACETS_MODULE_CI_REF` | no | `github-actions` ref the core is fetched from (default `v1`) |
| `FACETS_MR_TOKEN` | no | a token that can write MR notes; enables the preview comment |

The control-plane bootstrap provisions the three required variables as masked CI/CD variables.

## Not yet supported

**Cleanup-on-close.** GitLab runs no pipeline when a merge request is closed, so deleting a
closed MR's preview needs a separate trigger (a webhook or a scheduled sweep). The core
already implements `cleanup` (ownership-checked); only the GitLab trigger is missing. Tracked
as a follow-up.
