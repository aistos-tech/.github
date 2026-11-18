#!/usr/bin/env bash
# Is this pipeline PR's "Beyond the ticket" section current, with every held item answered?
#
#   scope-check.sh --base <ref> --head <ref> --body-file <file> [--labels <a,b>] [--manifest-ref <ref>] [--project-dir <dir>]
#   scope-check.sh --pr <n> [--project-dir <dir>]
#   scope-check.sh --id --base <ref> [--head <ref>] [--project-dir <dir>]   prints the scope id only
#
# exit 0 -> pass: no uiPaths, no interface change, a PR without the pipeline marker (a notice), or a
#           current section with no held item. Also an infrastructure error (no manifest, a fetch
#           failure, an unknown ref): it fails OPEN with a warning, so an outage never blocks a PR.
# exit 1 -> fail: the section is missing or malformed, its scope id is stale, a held item is listed,
#           or the PR carries `scope:held`. The message prints the section to paste.
# exit 2 -> usage.
#
# The rule behind it: aistos-dev's includes/scope-guard.md. The scope id is the patch-id of the PR's
# OWN `uiPaths` diff from its merge base, as aistos-ui-evidence-check measures evidence: a stack
# cascade or a rebase that leaves that diff unchanged keeps the id, and the base's own UI changes are
# not counted. It proves the section is current, not that no creep exists.
#
# One source: aistos-tech/.github scripts/scope-check.sh. aistos-dev vendors it as
# bin/aistos-scope-check, with a parity test. Bash, git and jq only: it runs on a bare runner.
# The PR body is data: it is read from a file or gh, never interpolated into a command.

set -uo pipefail
ME=${0##*/}
MARKER='<!-- aistos:scope -->'
HELD_LABEL='scope:held'

warn() { printf '%s: %s\n' "$ME" "$1" >&2; }
note() { printf '%s: %s\n' "$ME" "$1"; }
usage() { sed -n '4,6p' "$0" | sed 's/^# *//' >&2; exit 2; }

BASE="" HEAD="" BODY_FILE="" PR="" PROJECT_DIR="" LABELS="" MANIFEST_REF="" ID_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)         BASE="${2-}"; shift ;;
    --head)         HEAD="${2-}"; shift ;;
    --body-file)    BODY_FILE="${2-}"; shift ;;
    --labels)       LABELS="${2-}"; shift ;;
    --manifest-ref) MANIFEST_REF="${2-}"; shift ;;
    --pr)           PR="${2-}"; shift ;;
    --project-dir)  PROJECT_DIR="${2-}"; shift ;;
    --id)           ID_ONLY=1 ;;
    -h|--help)      usage ;;
    *)              usage ;;
  esac
  shift
done
if [ -n "$ID_ONLY" ]; then [ -n "$BASE" ] || usage
else [ -n "$PR" ] || { [ -n "$BASE" ] && [ -n "$BODY_FILE" ]; } || usage; fi
command -v jq >/dev/null 2>&1 || { warn "jq not found, check skipped"; exit 0; }

ROOT=${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { warn "no repository, check skipped"; exit 0; }
g() { git -C "$ROOT" "$@"; }

BODY=""
if [ -n "$PR" ]; then
  command -v gh >/dev/null 2>&1 || { warn "gh not found, check skipped"; exit 0; }
  INFO=$(cd "$ROOT" && gh pr view "$PR" --json body,baseRefName,headRefName,headRefOid,labels 2>/dev/null) \
    || { warn "could not read PR #$PR, check skipped"; exit 0; }
  BODY=$(printf '%s' "$INFO" | jq -r '.body // ""')
  LABELS=$(printf '%s' "$INFO" | jq -r '[.labels[].name] | join(",")')
  base_ref=$(printf '%s' "$INFO" | jq -r '.baseRefName')
  head_ref=$(printf '%s' "$INFO" | jq -r '.headRefName')
  HEAD=$(printf '%s' "$INFO" | jq -r '.headRefOid')
  g fetch -q origin "$base_ref" "$head_ref" 2>/dev/null || warn "fetch failed, using local refs"
  BASE="origin/$base_ref"
else
  [ -n "$ID_ONLY" ] || BODY=$(cat "$BODY_FILE" 2>/dev/null) || { warn "cannot read $BODY_FILE, check skipped"; exit 0; }
  [ -n "$HEAD" ] || HEAD=HEAD
  g rev-parse -q --verify "origin/$BASE^{commit}" >/dev/null 2>&1 && BASE="origin/$BASE"
fi
g rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { warn "unknown base $BASE, check skipped"; exit 0; }
g rev-parse -q --verify "$HEAD^{commit}" >/dev/null 2>&1 || { warn "unknown head $HEAD, check skipped"; exit 0; }

# The manifest comes from the base when CI asks (--manifest-ref), so a PR cannot narrow its own
# trigger; locally, from the working tree.
if [ -n "$MANIFEST_REF" ]; then
  MANIFEST=$(g show "$MANIFEST_REF:.claude/aistos-workflow.json" 2>/dev/null)
else
  MANIFEST=$(cat "$ROOT/.claude/aistos-workflow.json" 2>/dev/null)
fi
[ -n "$MANIFEST" ] || { note "scope check: none (no manifest)"; exit 0; }
INCLUDE=$(printf '%s' "$MANIFEST" | jq -r '.uiPaths.include // empty' 2>/dev/null)
[ -n "$INCLUDE" ] || { note "scope check: none (no uiPaths)"; exit 0; }
EXCLUDE=$(printf '%s' "$MANIFEST" | jq -r '.uiPaths.exclude // empty' 2>/dev/null)

MB=$(g merge-base "$BASE" "$HEAD" 2>/dev/null) || { warn "no merge base with $BASE, check skipped"; exit 0; }
FILES=$(g diff --name-only "$MB" "$HEAD" | grep -E -- "$INCLUDE")
if [ -n "$EXCLUDE" ] && [ -n "$FILES" ]; then FILES=$(printf '%s\n' "$FILES" | grep -vE -- "$EXCLUDE"); fi
if [ -z "$FILES" ]; then
  [ -n "$ID_ONLY" ] && { echo none; exit 0; }
  note "scope check: no interface change"; exit 0
fi
SCOPE_ID=$(printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 git -C "$ROOT" diff "$MB" "$HEAD" -- | git -C "$ROOT" patch-id --stable | cut -d' ' -f1)
[ -n "$SCOPE_ID" ] || SCOPE_ID=none
[ -n "$ID_ONLY" ] && { echo "$SCOPE_ID"; exit 0; }

TEMPLATE=$(printf '%s\n### Beyond the ticket\n\nKept:\n- none\n\nHeld for the owner:\n- none\n\nScope checked: %s\n' "$MARKER" "$SCOPE_ID")
fail() {
  printf '%s: %s\n' "$ME" "$1" >&2
  printf '\nInterface files in this PR:\n%s\n\nSection to put under "## Deviations from the ticket" (list the real kept and held items):\n\n%s\n' \
    "$FILES" "$TEMPLATE" >&2
  exit 1
}

if ! printf '%s\n' "$BODY" | grep -qF -- "$MARKER"; then
  note "scope check: not a pipeline PR (no $MARKER), passing. A pipeline PR adds this section:"
  printf '\n%s\n' "$TEMPLATE"
  exit 0
fi

case ",$LABELS," in *",$HELD_LABEL,"*)
  fail "the PR carries $HELD_LABEL: a held item waits for the owner. Answer it, refresh the section, then remove the label." ;;
esac

SECTION=$(printf '%s\n' "$BODY" | sed -n "/$(printf '%s' "$MARKER" | sed 's/[][\.*^$/]/\\&/g')/,\$p")
printf '%s\n' "$SECTION" | grep -qE '^###[[:space:]]+Beyond the ticket[[:space:]]*$' \
  || fail "the marker is there but the \"### Beyond the ticket\" heading is missing."
CHECKED=$(printf '%s\n' "$SECTION" | grep -oE '^Scope checked:[[:space:]]*`?[0-9a-f]{40}|^Scope checked:[[:space:]]*none' | head -1 | grep -oE '[0-9a-f]{40}|none$')
[ -n "$CHECKED" ] || fail "the section has no \"Scope checked: <id>\" line."
HELD=$(printf '%s\n' "$SECTION" | sed -n '/^Held for the owner:/,/^Scope checked:/p' | grep -cE '^[[:space:]]*[0-9]+\.[[:space:]]')
[ "$HELD" -eq 0 ] || fail "the section lists $HELD held item(s): the owner answers them first."
[ "$CHECKED" = "$SCOPE_ID" ] \
  || fail "the interface diff changed since the section was written (section: $CHECKED, now: $SCOPE_ID). Re-check the new UI changes against the ticket and refresh the section."
note "scope check: current ($SCOPE_ID), no held item"
exit 0
