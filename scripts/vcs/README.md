# VCS adapter

Provider-agnostic shell scripts for the pull-request / merge-request lifecycle. The
entry scripts share one CLI surface; `lib.sh` dispatches to a provider implementation
chosen by `VCS_PROVIDER` (`github` | `gitlab`), **auto-detected from the `origin`
remote** when unset. All commands run against the repo in the current directory.

| Script | Does |
|---|---|
| `default-branch.sh` | Print the repo's default/parent branch |
| `open-pr.sh`        | Open (or reuse) a PR/MR for HEAD → BASE; prints the URL + `number=`. `--media <ref>` (repeatable) attaches visual results to the body |
| `upload-media.sh`   | Host media (image/video files, a dir of them, or http(s) URLs) and print an embeddable **## Visual results** markdown section |
| `pr-view.sh`        | Print `state=<MERGED\|OPEN\|CLOSED>` + `merge_sha=` |
| `pr-comment.sh`     | Comment on a PR/MR (inline at `--path`:`--line` where supported) — review comments must anchor + quote code (see Notes) |
| `pr-comments.sh`    | Print a PR/MR's comments / review notes as plain text |
| `merge-pr.sh`       | **Squash-merge server-side** so the web PR/MR shows *Merged*, then prints pr-view |

`open-pr.sh`, `upload-media.sh`, `pr-comment.sh`, and `merge-pr.sh` accept `--dry-run`.

## Layout

```
vcs/
├── lib.sh             # provider dispatch (+ git-based default-branch)
├── github.sh          # gh implementation
├── gitlab.sh          # glab implementation
├── default-branch.sh  open-pr.sh  pr-view.sh  pr-comment.sh  merge-pr.sh
└── .env.example       # optional VCS_PROVIDER override
```

A provider impl defines: `vcs_require_config`, `vcs_open_pr`, `vcs_pr_view`,
`vcs_pr_comment`, `vcs_pr_comments`, `vcs_merge_pr`, `vcs_upload_media`. **To add a host**
(e.g. Bitbucket), drop a new `<provider>.sh` implementing those — nothing else changes.
Shared media helpers (`vcs_is_image`, `vcs_is_media`, `vcs_media_md`,
`vcs_media_asset_name`) live in `lib.sh`.

## Auth

Handled by the provider CLI, not this adapter:
- **GitHub** — `gh auth login` (or `GH_TOKEN`/`GITHUB_TOKEN`).
- **GitLab** — `glab auth login` (or `GITLAB_TOKEN`; `GITLAB_HOST` for self-managed).

## Notes

- **Attaching visual results.** `open-pr.sh --media <ref>` (repeatable: file, directory,
  or http(s) URL) hosts each item and appends a **## Visual results** section to the body.
  Hosting differs by provider: **GitLab** uses the project uploads API (images and video
  render inline); **GitHub** has no token-scriptable PR-body attachment, so the adapter
  hosts assets on a dedicated **`pr-media`** release (tag overridable via
  `VCS_MEDIA_RELEASE`) and links them — images render inline, video shows as a download
  link (GitHub only inline-plays its own web uploads). Media is embedded at **create**
  time only; reusing an existing PR/MR does not rewrite the body.
- **Review-comment convention (all reviewers).** Every review comment MUST anchor to
  the code: pass `--path` + `--line` so it lands inline at the exact spot, **and** quote
  the offending line or block as a fenced code snippet in `--body`. No vague,
  location-less review comments — this applies to the code reviewer (Daniel), the
  guardian (Ethan), and the performance reviewer (Liam) alike. On GitLab, where the
  inline position can't be set, the adapter still references `path:line` in the note, so
  the quoted snippet in `--body` is what makes the comment self-contained there.
- "PR" maps to a GitLab **merge request**; a PR `number` is the **MR IID**.
- Inline-at-line comments are a true review comment on GitHub; on GitLab the adapter
  posts an MR **note** that references `path:line` (positioned discussions are
  glab-version-specific — kept robust on purpose).
- `glab` flags target a recent version (~1.40+); if yours differs, `gitlab.sh` is the
  one file to adjust.
