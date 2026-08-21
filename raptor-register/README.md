# Facets Artifact Register

Registers an already-pushed image against a Facets **artifact**, using the
[`raptor`](https://github.com/Facets-cloud/raptor-releases/releases) CLI.

It registers; it does not build or push. Build and push with whatever your pipeline
already uses, then hand the resulting URI to this action.

```yaml
- uses: Facets-cloud/github-actions/raptor-register@v1
  with:
    control_plane_url: ${{ secrets.FACETS_CP_URL }}
    username: ${{ secrets.FACETS_USERNAME }}
    token: ${{ secrets.FACETS_TOKEN }}
    project: my-project
    artifact: my-project-api
    image: my.registry.example.com/my-project/api:${{ github.sha }}
    git_ref: ${{ github.ref_name }}
    registry: my-ecr
```

## Where the build lands

Exactly one of three inputs, and the choice is the whole behaviour:

| Input | What happens |
|---|---|
| `git_ref` | The branch is matched against the project's routing rules, and **they** decide the target. A branch that matches nothing leaves the build registered but unrouted. |
| `environment` | Registered straight to that environment. No rules consulted. |
| `release_stream` | Registered straight to that stream. No rules consulted. |

An artifact takes environments or release streams, never both — it is fixed when the
artifact is created. `raptor get artifacts -p <project>` shows which.

To see what a project's rules actually say, and where builds landed:

```bash
raptor get ci-cd -p <project> -a <artifact>     # the branch mapping and promotion ladder
raptor get builds <artifact> -p <project>       # what is registered; flags unrouted builds
```

## `registry` decides whether the resource can find the build

A resource asks for its image in one of two shapes. Read which one with
`raptor get resources -p PROJECT RESOURCE -o json`:

| shape | how it resolves | `registry` |
|---|---|---|
| `spec.release.image: ${blueprint.self.artifacts.NAME}` | by artifact name | not needed |
| `spec.release.build: {name: NAME, artifactory: REG}` | by registry, then name | **required, and it must be REG** |

The module resolves the second shape as `all_artifactories[REG][NAME]`. A build stored
under another registry is absent from that map, so the module falls back to the literal
string `NOT_FOUND` and deploys **that**. The pod then sits in `InvalidImageName`, and
nothing failed earlier to warn you. Read what a build carries with
`raptor get builds ARTIFACT -p PROJECT -o wide`.

## Which artifact?

Not always the resource name — the artifact is the CI integration a resource deploys
from, and one artifact is often shared by several resources across several projects.
Read it off the resource listing rather than guessing:

```bash
raptor get resources -p <project> -o wide       # the ARTIFACT column
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `control_plane_url` | yes | | Control Plane URL, e.g. `https://your-org.console.facets.cloud` |
| `username` | yes | | Facets username |
| `token` | yes | | Facets API token — pass a secret, never a literal |
| `project` | yes | | Project (blueprint) the artifact belongs to |
| `artifact` | yes | | Artifact to register against |
| `image` | yes | | Full image URI including the tag; must already be pushed |
| `git_ref` | one of three | `""` | Register against this branch and let the rules place it |
| `environment` | one of three | `""` | Register directly against this environment |
| `release_stream` | one of three | `""` | Register directly against this release stream |
| `registry` | see above | `""` | Registry the image lives in |
| `external_id` | no | this run's id | CI reference recorded on the build |
| `raptor_version` | no | `latest` | `latest` or an exact tag, e.g. `v0.1.98`. `--registry` needs v0.1.98 or later |
| `raptor-download-url` | no | `""` | Exact binary URL; overrides `raptor_version` |

## Notes

- **The token is scoped to one step.** Auth is set as a step-level `env:` inside the
  action, so it is not exported into the rest of the caller's job.
- **Pushing to a Facets registry?** Get the credentials and the repository to tag
  against from raptor, in the step before this one — the control plane owns the
  repository name, so it is not something to assemble by hand:

  ```bash
  raptor get registry-credentials <registry> -p <project> -a <artifact>                    # docker login
  REPO=$(raptor get registry-credentials <registry> -p <project> -a <artifact> --repository-uri)
  ```

- **Zip bundles** are not this action: `raptor set artifact-zip` uploads and registers
  in one command, with no registry involved.

## Replaces `facetsctl-register`

[`facetsctl-register`](../.github/actions/facetsctl-register/action.yml) is deprecated. It runs
facetsctl **v2** in a Docker action and reads `secrets.*` from inside the action, which
is not a context an action can read — so its credentials arrive empty. Migrating:

| facetsctl-register | raptor-register |
|---|---|
| `docker_image` | `image` |
| `service` | `artifact` (read it from the ARTIFACT column, see above) |
| `blueprint_name` | `project` (now required) |
| `git_ref` | `git_ref` |
| `external_id` | `external_id` (optional; defaults to the run id) |
| `registration_type` | drop it — the target input you pass says which mode you are in |
| `registry` | `registry` — keep it. It is not decoration: see the note above |
| `description` | drop it — not carried on a build registration |
| implicit `secrets.FACETS_*` | explicit `control_plane_url` / `username` / `token` inputs |
