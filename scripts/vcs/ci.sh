#!/usr/bin/env bash
# Read a repo's CI: its recent runs (GitLab pipelines / GitHub Actions runs), a run's jobs, and a
# job's raw log. Read-only — never retries, cancels or triggers anything — so it pipes freely.
#
#   ./ci.sh runs [--source <s>] [--ref <branch>] [--since YYYY-MM-DD] [--limit N]
#        -> <run id> TAB <status> TAB <source> TAB <ref> TAB <created> TAB <url>     (newest first)
#   ./ci.sh jobs <run id>
#        -> <job id> TAB <status> TAB <stage> TAB <name> TAB <started> TAB <url>
#   ./ci.sh log <job id>
#        -> the job's log, verbatim. Logs are large: pipe to grep/tail, or redirect to a file.
#
# --source is the forge's own word for what started the run: GitLab `schedule|push|web|
# merge_request_event|…`, GitHub `schedule|push|pull_request|workflow_dispatch|…`.
# Acts on the current directory's repo unless VCS_REPO names another (see README).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="Usage: ci.sh runs [--source <s>] [--ref <branch>] [--since YYYY-MM-DD] [--limit N] | jobs <run id> | log <job id>"
for a in "$@"; do case "$a" in -h|--help) echo "$usage"; exit 0 ;; esac; done
# shellcheck source=lib.sh
. "$DIR/lib.sh"

sub="${1:-}"; [[ $# -gt 0 ]] && shift
case "$sub" in
  runs)
    limit=20; source=''; ref=''; since=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source) source="${2:-}"; shift 2 ;;
        --ref)    ref="${2:-}";    shift 2 ;;
        --since)  since="${2:-}";  shift 2 ;;
        --limit)  limit="${2:-}";  shift 2 ;;
        *) die "unknown option: $1   ($usage)" ;;
      esac
    done
    [[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 && "$limit" -le 100 ]] || die "--limit must be 1..100 (one page of the forge's API)"
    [[ -z "$since" || "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--since must be YYYY-MM-DD"
    vcs_ci_runs "$limit" "$source" "$ref" "$since" ;;
  jobs|log)
    [[ "${1:-}" =~ ^[0-9]+$ ]] || die "$sub needs a numeric id   ($usage)"
    if [[ "$sub" == jobs ]]; then vcs_ci_jobs "$1"; else vcs_ci_job_log "$1"; fi ;;
  *) die "$usage" ;;
esac
