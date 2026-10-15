#!/usr/bin/env bash
# Facets Module CI — host-neutral core.
#
# Shared by the GitHub action (module-ci-action) and the GitLab template
# (module-ci-gitlab). Each host supplies thin glue that resolves the mode,
# the git diff range, and the ownership SHAs, then calls this script; the
# host posts the review comment this script writes to $CI_COMMENT_DIR.
#
# Generic env contract (host glue sets these — this script reads NOTHING
# host-specific like GITHUB_* or CI_MERGE_REQUEST_*):
#   MODE               preview | publish | cleanup | noop
#   CI_DIFF_RANGE      git range for changed files ("base..head" / "base...head");
#                      empty => diff-tree against HEAD (new branch / unknown base)
#   CI_HEAD_SHA        commit a preview is pinned to (preview mode)
#   CI_OWNER_SHAS      newline-separated commit SHAs that own previews (cleanup);
#                      empty => cannot verify ownership, cleanup skipped
#   PATH_PREFIX        sub-path to modules/ (e.g. "infra/"); empty => repo root
#   ALL_MODULES        "true" => every module/output, not just changed ones
#   APPLY_OUTPUT_TYPES "true" (default) => apply outputs/ before modules
#   AUTO_CREATE_INTENTS "true" (default) => raptor --auto-create for new intents
#   CONTROL_PLANE_URL / FACETS_USERNAME / FACETS_TOKEN   raptor auth (read by raptor)
#   RAPTOR_VERSION / RAPTOR_DOWNLOAD_URL / TERRAFORM_VERSION / TRIVY_VERSION
#   CI_COMMENT_DIR     dir to write preview_outputs.md / preview_modules.md
#                      (default: a temp dir, printed at the end)
set -uo pipefail

MODE="${MODE:-noop}"
PATH_PREFIX="${PATH_PREFIX:-}"
ALL_MODULES="${ALL_MODULES:-false}"
APPLY_OUTPUT_TYPES="${APPLY_OUTPUT_TYPES:-true}"
AUTO_CREATE_INTENTS="${AUTO_CREATE_INTENTS:-true}"
RAPTOR_VERSION="${RAPTOR_VERSION:-latest}"
RAPTOR_DOWNLOAD_URL="${RAPTOR_DOWNLOAD_URL:-}"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.5.7}"
TRIVY_VERSION="${TRIVY_VERSION:-0.72.0}"
WORK="$(mktemp -d)"
CI_COMMENT_DIR="${CI_COMMENT_DIR:-$WORK}"
FAILURES="${WORK}/ci_failures"
mkdir -p "$CI_COMMENT_DIR"
# Keep raptor's Trivy scan out of terraform-init'd dependency trees (issue #13).
export TRIVY_SKIP_DIRS="${TRIVY_SKIP_DIRS:-**/.terraform,**/.terraform/**}"

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$1" >> "$FAILURES"; }

# --- shared helpers (identical to the GitHub action's inline copies) ----------

# Read a top-level scalar key (intent/flavor/version) from a module's facets.yaml.
meta() {
  sed -n -E "s/^$2:[[:space:]]*(.*)$/\1/p" "$1/facets.yaml" | head -n1 \
    | sed -E "s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*$//"
}

# Changed files for this event, via the host-formed CI_DIFF_RANGE. Empty range
# (new branch / unreachable base) falls back to the pushed commit's own tree so
# git diff never errors and silently skips every module.
changed_files() {
  if [ -n "${CI_DIFF_RANGE:-}" ]; then
    git diff --name-only "${CI_DIFF_RANGE}"
  else
    git diff-tree --no-commit-id --name-only -r HEAD
  fi
}

# Map a changed file to the nearest ANCESTOR dir holding a facets.yaml, so a
# change deep inside a module (templates/foo.tpl) still maps to the module root.
find_module_dir() {
  local d
  d="$(dirname "$1")"
  while [ -n "$d" ] && [ "$d" != "." ] && [ "$d" != "/" ]; do
    if [ -f "$d/facets.yaml" ]; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  if [ -f "facets.yaml" ]; then printf '%s\n' "."; fi
}

is_definition() {
  case "${1,,}" in
    *.yaml|*.yml|*.json) return 0 ;;
    *) return 1 ;;
  esac
}

prefix() {
  local p="$PATH_PREFIX"
  if [ -n "$p" ] && [ "${p%/}" = "$p" ]; then p="${p}/"; fi
  printf '%s' "$p"
}

install_tools() {
  # Install only what's missing — a fresh CI runner installs all three; a dev
  # machine that already has them is a no-op. Modes that don't run raptor's
  # module validation (cleanup/noop) don't need terraform/trivy.
  local p; p="$(prefix)"
  if ! command -v raptor >/dev/null 2>&1; then
    local url
    if [ -n "$RAPTOR_DOWNLOAD_URL" ]; then url="$RAPTOR_DOWNLOAD_URL"
    elif [ -z "$RAPTOR_VERSION" ] || [ "$RAPTOR_VERSION" = "latest" ]; then
      url="https://github.com/Facets-cloud/raptor-releases/releases/latest/download/raptor-linux-amd64"
    else
      url="https://github.com/Facets-cloud/raptor-releases/releases/download/${RAPTOR_VERSION}/raptor-linux-amd64"
    fi
    log "Installing raptor from ${url}"
    curl -fsSL -o /tmp/raptor "$url" && chmod +x /tmp/raptor && sudo mv /tmp/raptor /usr/local/bin/raptor
  else
    log "raptor already present: $(command -v raptor)"
  fi
  if [ "$MODE" = "preview" ] || [ "$MODE" = "publish" ]; then
    if ! command -v terraform >/dev/null 2>&1; then
      log "Installing Terraform ${TERRAFORM_VERSION}..."
      curl -fsSL -o /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        && (cd /tmp && unzip -o tf.zip terraform) && sudo mv /tmp/terraform /usr/local/bin/terraform
    fi
    if ! command -v trivy >/dev/null 2>&1; then
      log "Installing Trivy ${TRIVY_VERSION}..."
      curl -fsSL -o /tmp/trivy.tgz "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        && (cd /tmp && tar -xzf trivy.tgz trivy) && sudo mv /tmp/trivy /usr/local/bin/trivy
    fi
  fi
}

# --- target detection ---------------------------------------------------------

detect_module_dirs() {
  local root; root="$(prefix)modules"
  local candidates="" dirs="" d f md
  if [ "$ALL_MODULES" = "true" ]; then
    [ -d "$root" ] && candidates="$(find "$root" -type f -name facets.yaml -exec dirname {} \; | sort -u)"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      md="$(find_module_dir "$f" || true)"
      [ -n "$md" ] && candidates="${candidates} ${md}"
    done <<< "$(changed_files || true)"
  fi
  for d in $candidates; do
    case "$d/" in "$root"/*) ;; *) continue ;; esac
    [ -f "$d/facets.yaml" ] && dirs="$dirs $d"
  done
  # shellcheck disable=SC2086  # intentional re-split of the space-separated list
  printf '%s\n' $dirs | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

detect_output_files() {
  local root; root="$(prefix)outputs"
  local files="" f
  if [ "$ALL_MODULES" = "true" ]; then
    [ -d "$root" ] && files="$(find "$root" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort)"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      case "$f/" in "$root"/*) ;; *) continue ;; esac
      [ -f "$f" ] || continue       # a deleted output is never a target
      is_definition "$f" || continue
      files="${files} ${f}"
    done <<< "$(changed_files || true)"
  fi
  # shellcheck disable=SC2086  # intentional re-split of the space-separated list
  printf '%s\n' $files | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# --- output types (applied BEFORE modules; a module refs its type by name) ----

apply_output_types() {
  local files="$1" section="${CI_COMMENT_DIR}/preview_outputs.md"
  [ -n "$files" ] || return 0
  local mode_flag=""
  [ "$MODE" = "preview" ] && mode_flag="--if-absent"
  { echo "### Facets output types"; echo; echo "| Definition | Type | Result | Reported changes |"; echo "|---|---|---|---|"; } > "$section"
  local file out result ref notes
  for file in $files; do
    log "::group::Output type ${file}"
    if out="$(raptor create output-type -f "$file" $mode_flag 2>&1)"; then
      printf '%s\n' "$out"
      result="$(printf '%s\n' "$out" | sed -n "s/^✓ Output type '.*' \(.*\)\$/\1/p" | tail -n1)"; [ -n "$result" ] || result="applied"
    else
      printf '%s\n' "$out"; log "::error::Output type apply failed for ${file}"; fail "${file} (output-type)"; result="failed"
    fi
    ref="$(printf '%s\n' "$out" | sed -n "s/^✓ Output type '\(@[^']*\)'.*\$/\1/p" | tail -n1)"
    notes="$(printf '%s\n' "$out" | sed -n 's/^  ⚠️  //p' | sed 's/|/\\|/g' | paste -sd ';' - | sed 's/;/; /g')"; [ -n "$notes" ] || notes="—"
    echo "| \`${file}\` | \`${ref:-?}\` | ${result} | ${notes} |" >> "$section"
    log "::endgroup::"
  done
  { echo; echo "_On a pull request an output type is only created when the control plane does not have it. An existing one is left untouched — any change listed against it lands when this PR merges._"; } >> "$section"
}

# --- modules ------------------------------------------------------------------

auto_create_flag() { [ "${AUTO_CREATE_INTENTS:-true}" = "true" ] && printf '%s' "--auto-create"; }

preview_modules() {
  local dirs="$1" comment="${CI_COMMENT_DIR}/preview_modules.md" ac; ac="$(auto_create_flag)"
  [ -n "$dirs" ] || return 0
  { echo "### Facets module preview"; echo; echo "This branch now owns the single **preview slot** for each module below (concurrent MRs on the same module: last push wins)."; echo; echo "| Module | Type | Flavor | Version | Result |"; echo "|---|---|---|---|---|"; } > "$comment"
  local dir type flavor version ref result ok
  for dir in $dirs; do
    log "::group::Preview ${dir}"
    type="$(meta "$dir" intent)"; flavor="$(meta "$dir" flavor)"; version="$(meta "$dir" version)"; ref="${type}/${flavor}/${version}"; result="previewed"; ok=1
    if [ -z "$type" ] || [ -z "$flavor" ] || [ -z "$version" ]; then log "::error::Could not read intent/flavor/version from ${dir}/facets.yaml"; fail "${dir} (metadata)"; result="bad facets.yaml"; ok=0; fi
    if [ "$ok" = 1 ] && ! raptor create iac-module -f "$dir" --dry-run; then log "::error::Validation failed for ${ref}"; fail "${ref} (validate)"; result="validation failed"; ok=0; fi
    # shellcheck disable=SC2086  # $ac is a deliberate empty-or-one-flag word
    if [ "$ok" = 1 ] && ! raptor create iac-module -f "$dir" $ac --feature-branch --git-ref "${CI_HEAD_SHA:-}"; then log "::error::Preview registration failed for ${ref}"; fail "${ref} (preview)"; result="preview failed"; ok=0; fi
    echo "| \`${dir}\` | ${type:-?} | ${flavor:-?} | ${version:-?} | ${result} |" >> "$comment"
    log "::endgroup::"
  done
  { echo; echo "_Previews are unpublishable feature-branch registrations pinned to the source commit. They are cleaned up when this request is closed (ownership-checked)._"; } >> "$comment"
}

publish_modules() {
  local dirs="$1" ac; ac="$(auto_create_flag)"
  [ -n "$dirs" ] || return 0
  local dir type flavor version ref modules_json declaration pub_any pub_target
  for dir in $dirs; do
    log "::group::Publish ${dir}"
    type="$(meta "$dir" intent)"; flavor="$(meta "$dir" flavor)"; version="$(meta "$dir" version)"
    if [ -z "$type" ] || [ -z "$flavor" ] || [ -z "$version" ]; then log "::error::Could not read intent/flavor/version from ${dir}/facets.yaml"; fail "${dir} (metadata)"; log "::endgroup::"; continue; fi
    ref="${type}/${flavor}/${version}"
    log "Uploading ${ref}..."
    # shellcheck disable=SC2086  # $ac is a deliberate empty-or-one-flag word
    if ! raptor create iac-module -f "$dir" $ac; then log "::error::Upload failed for ${ref}"; fail "${ref} (upload)"; log "::endgroup::"; continue; fi
    if ! modules_json="$(raptor get iac-module -o json 2>/dev/null)"; then log "::error::Could not list modules for ${ref}"; fail "${ref} (publish)"; log "::endgroup::"; continue; fi
    _family() { printf '%s' "$modules_json" | jq -r --arg t "$type" --arg f "$flavor" --arg v "$1" '(if type=="array" then . else [] end) | map(select(.intent==$t and .flavor==$f and .stage=="PUBLISHED" and ($v=="" or .version==$v))) | length' 2>/dev/null || echo ""; }
    pub_any="$(_family "")"; pub_target="$(_family "$version")"
    if [ -z "$pub_any" ] || [ -z "$pub_target" ]; then log "::error::Could not read published versions of ${type}/${flavor} for ${ref}"; fail "${ref} (publish)"; log "::endgroup::"; continue; fi
    declaration=""
    if [ "$pub_target" != "0" ]; then declaration="--backward-compatible yes"; log "${version} already published: declaring a compatible update."
    elif [ "$pub_any" != "0" ]; then declaration="--versionupgrade"; log "${version} is a new contract version: declaring a version upgrade."
    else log "First publication of ${type}/${flavor}: no declaration needed."; fi
    log "Publishing ${ref}..."
    # shellcheck disable=SC2086  # $declaration is a deliberate empty-or-flag word list
    if ! raptor publish iac-module "$ref" $declaration; then log "::error::Publish failed for ${ref}"; fail "${ref} (publish)"; log "::endgroup::"; continue; fi
    log "Published ${ref}"; log "::endgroup::"
  done
}

cleanup_previews() {
  local dirs="$1"
  [ -n "$dirs" ] || return 0
  if [ -z "${CI_OWNER_SHAS:-}" ]; then log "::warning::No ownership SHAs provided; preview ownership can't be verified. Skipping cleanup."; return 0; fi
  local modules_json list_ok
  if modules_json="$(raptor get iac-module -o json 2>/dev/null)"; then list_ok=1; else list_ok=0; modules_json='[]'; log "::warning::Could not list modules; cleanup will skip every module."; fi
  _owner_sha() { printf '%s' "$modules_json" | jq -r --arg t "$1" --arg f "$2" --arg v "$3" '(if type=="array" then . else [] end) | map(select(.intent==$t and .flavor==$f and .version==$v)) as $rows | ($rows | map(select(.stage=="PREVIEW"))[0]) as $p | ($rows | map(select(.stage=="PUBLISHED" and ((.previewModuleId // "") != "")))[0]) as $pub | if $p then ($p.gitRef // "") elif $pub then ($pub.previewGitRef // "") else "" end' 2>/dev/null || true; }
  _rows() { printf '%s' "$modules_json" | jq -r --arg t "$1" --arg f "$2" --arg v "$3" '(if type=="array" then . else [] end) | map(select(.intent==$t and .flavor==$f and .version==$v)) | length' 2>/dev/null || echo 0; }
  local dir type flavor version ref owner owned sha fresh
  for dir in $dirs; do
    log "::group::Cleanup ${dir}"
    type="$(meta "$dir" intent)"; flavor="$(meta "$dir" flavor)"; version="$(meta "$dir" version)"
    if [ -z "$type" ] || [ -z "$flavor" ] || [ -z "$version" ]; then log "::warning::Could not read facets.yaml for ${dir}; skipping."; log "::endgroup::"; continue; fi
    ref="${type}/${flavor}/${version}"
    owner="$(_owner_sha "$type" "$flavor" "$version")"
    if [ -z "$owner" ] || [ "$owner" = "null" ]; then
      if [ "$list_ok" = 1 ] && [ "$(_rows "$type" "$flavor" "$version")" != "0" ]; then log "::warning::${ref} is in the registry but no owning commit resolved; skipping."; else log "No preview slot recorded for ${ref}; nothing to clean up."; fi
      log "::endgroup::"; continue
    fi
    owned="false"; while IFS= read -r sha; do [ -z "$sha" ] && continue; [ "$sha" = "$owner" ] && { owned="true"; break; }; done <<< "${CI_OWNER_SHAS}"
    if [ "$owned" != "true" ]; then log "Preview for ${ref} is owned by another branch (commit=${owner}); leaving it."; log "::endgroup::"; continue; fi
    fresh="$(_owner_sha_fresh "$type" "$flavor" "$version")"
    if [ "$fresh" != "$owner" ]; then log "::warning::Preview slot for ${ref} changed between check and delete (was ${owner}, now ${fresh:-none}); skipping."; log "::endgroup::"; continue; fi
    log "Deleting preview for ${ref} (owned by this request, commit=${owner})..."
    if ! raptor delete iac-module "$ref" --stage PREVIEW --yes; then log "::error::Failed to delete preview for ${ref}"; fail "${ref} (cleanup)"; fi
    log "::endgroup::"
  done
}
# TOCTOU re-check: re-fetch the live slot owner right before delete.
_owner_sha_fresh() { printf '%s' "$(raptor get iac-module -o json 2>/dev/null || echo '[]')" | jq -r --arg t "$1" --arg f "$2" --arg v "$3" '(if type=="array" then . else [] end) | map(select(.intent==$t and .flavor==$f and .version==$v)) as $rows | ($rows | map(select(.stage=="PREVIEW"))[0]) as $p | ($rows | map(select(.stage=="PUBLISHED" and ((.previewModuleId // "") != "")))[0]) as $pub | if $p then ($p.gitRef // "") elif $pub then ($pub.previewGitRef // "") else "" end' 2>/dev/null || true; }

report_gate() {
  log "=== Facets Module CI summary (mode: ${MODE}) ==="
  if [ -f "$FAILURES" ] && [ -s "$FAILURES" ]; then
    log "The following modules failed:"; sed 's/^/  - /' "$FAILURES"; return 1
  fi
  log "All processed modules succeeded (or there was nothing to do)."; return 0
}

# --- main ---------------------------------------------------------------------

if [ "$MODE" = "noop" ]; then log "Mode is noop; nothing to do."; exit 0; fi
install_tools

DIRS="$(detect_module_dirs)"
log "Target module dirs: ${DIRS:-<none>}"
case "$MODE" in
  preview|publish)
    if [ "${APPLY_OUTPUT_TYPES}" = "true" ]; then
      OUT="$(detect_output_files)"; log "Target output defs: ${OUT:-<none>}"
      apply_output_types "$OUT"
    fi
    if [ "$MODE" = "preview" ]; then preview_modules "$DIRS"; else publish_modules "$DIRS"; fi
    ;;
  cleanup) cleanup_previews "$DIRS" ;;
  *) log "::error::Unknown MODE '${MODE}'"; exit 1 ;;
esac

log "Comment markdown in: ${CI_COMMENT_DIR}"
report_gate
