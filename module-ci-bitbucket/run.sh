#!/usr/bin/env bash
# Facets Module CI — Bitbucket Pipelines glue.
#
# The Bitbucket counterpart of module-ci-action (GitHub) and module-ci-gitlab
# (GitLab). It runs the SAME shared module-ci-core.sh the other hosts run, so the
# three never drift — this file is only the thin Bitbucket glue: resolve the mode,
# map Bitbucket's predefined variables to the generic MC_* contract, fetch + run
# the core, and post the pull-request preview as a comment.
#
# Bitbucket Pipelines has no remote-include (unlike GitLab's `include: remote:`),
# so the modules repo's bitbucket-pipelines.yml can't pull a hosted template. It
# instead curls THIS script (pinned to a tag) and runs it — the control plane
# wires that in at bootstrap, the same way it wires module-ci-action@v1 (GitHub)
# or the GitLab include.
#
# Required repository variables (set by the control-plane bootstrap, masked):
#   CONTROL_PLANE_URL, FACETS_USERNAME, FACETS_TOKEN
# Optional:
#   FACETS_PATH_PREFIX    sub-path to modules/ (default "": modules/ at repo root)
#   FACETS_MODULE_CI_REF  github-actions ref the core is fetched from (default "v1")
#   FACETS_PR_TOKEN       a Bitbucket access token that can write PR comments; when
#                         set, the preview is posted as a PR comment (mirrors the
#                         GitHub github_token / GitLab FACETS_MR_TOKEN)
#
# NOTE (v1 scope): preview (on pull request) and publish (on default-branch push)
# are supported. Cleanup-on-close is not — Bitbucket runs no pipeline when a PR is
# closed, so preview cleanup needs a separate trigger (a webhook or a scheduled
# sweep); the core already implements `cleanup`, only the Bitbucket trigger is
# missing. Tracked as a follow-up, same as GitLab.
set -euo pipefail

FACETS_MODULE_CI_REF="${FACETS_MODULE_CI_REF:-v1}"
export PATH_PREFIX="${FACETS_PATH_PREFIX:-}"
export MC_COMMENT_DIR="${BITBUCKET_CLONE_DIR:-$PWD}/.facets-mci"
mkdir -p "$MC_COMMENT_DIR"

if [ -n "${BITBUCKET_PR_ID:-}" ]; then
  # Pull-request build: Bitbucket checks out the source branch, so HEAD is the
  # source head. Diff against the merge base with the destination branch.
  export MODE="preview"
  export MC_HEAD_SHA="${BITBUCKET_COMMIT}"
  dest="${BITBUCKET_PR_DESTINATION_BRANCH}"
  git fetch -q origin "$dest" || true
  base="$(git merge-base "origin/${dest}" HEAD 2>/dev/null || true)"
  # Empty base (unreachable) => core falls back to the pushed commit's own tree.
  export MC_DIFF_RANGE="${base:+${base}..${BITBUCKET_COMMIT}}"
else
  # Default-branch push: publish. Bitbucket exposes no "previous commit" variable
  # like GitLab's CI_COMMIT_BEFORE_SHA, so diff the single merge commit.
  # ponytail: HEAD~1..HEAD assumes a squash/merge lands one commit (the Facets
  # squash-merge workflow). A multi-commit fast-forward would only CI the tip's
  # changes; widen the range here if that workflow is ever adopted.
  export MODE="publish"
  if git rev-parse --verify --quiet "HEAD~1^{commit}" >/dev/null 2>&1; then
    export MC_DIFF_RANGE="HEAD~1..HEAD"
  else
    export MC_DIFF_RANGE=""
  fi
fi

curl -fsSL "https://raw.githubusercontent.com/Facets-cloud/github-actions/${FACETS_MODULE_CI_REF}/module-ci-core.sh" -o /tmp/module-ci-core.sh

# after_script equivalent: post the preview comment even when the core gates on a
# bad module (mirrors the GitHub comment's if: always() and GitLab's after_script).
post_preview_comment() {
  [ "${MODE}" = "preview" ] || return 0
  if [ -z "${FACETS_PR_TOKEN:-}" ]; then
    echo "FACETS_PR_TOKEN not set; skipping PR preview comment."
    return 0
  fi
  local body_file api existing marker="<!-- facets-module-ci:preview -->"
  body_file="$(mktemp)"
  printf '%s\n' "$marker" > "$body_file"
  [ -f "${MC_COMMENT_DIR}/preview_outputs.md" ] && { cat "${MC_COMMENT_DIR}/preview_outputs.md" >> "$body_file"; echo "" >> "$body_file"; }
  [ -f "${MC_COMMENT_DIR}/preview_modules.md" ] && cat "${MC_COMMENT_DIR}/preview_modules.md" >> "$body_file"
  if [ ! -s "${MC_COMMENT_DIR}/preview_outputs.md" ] && [ ! -s "${MC_COMMENT_DIR}/preview_modules.md" ]; then
    echo "No preview comment body; nothing to post."
    return 0
  fi
  api="https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${BITBUCKET_PR_ID}/comments"
  # Upsert: find an existing bot comment carrying our marker, else create one.
  existing="$(curl -fsS -H "Authorization: Bearer ${FACETS_PR_TOKEN}" "${api}?pagelen=100" \
    | jq -r --arg m "$marker" '.values[] | select(.content.raw | contains($m)) | .id' | head -n1 || true)"
  local payload
  payload="$(jq -Rs '{content:{raw:.}}' < "$body_file")"
  if [ -n "$existing" ]; then
    curl -fsS -X PUT -H "Authorization: Bearer ${FACETS_PR_TOKEN}" -H "Content-Type: application/json" \
      -d "$payload" "${api}/${existing}" >/dev/null && echo "Updated PR preview comment ${existing}."
  else
    curl -fsS -X POST -H "Authorization: Bearer ${FACETS_PR_TOKEN}" -H "Content-Type: application/json" \
      -d "$payload" "${api}" >/dev/null && echo "Posted PR preview comment."
  fi
}
trap post_preview_comment EXIT

bash /tmp/module-ci-core.sh
