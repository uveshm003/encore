# Branch protection

`main` is protected by a repository ruleset. The active configuration is kept
in [`.github/rulesets/main.json`](../.github/rulesets/main.json) so that what
GitHub enforces is reviewable in a diff rather than being a setting somebody
changed once. JSON carries no comments, so the reasoning lives here.

## Applying it

GitHub does not read this file automatically — a ruleset is server-side state
and the file is a record of it. To apply:

**From the web interface.** Settings → Rules → Rulesets → New ruleset → Import
a ruleset, and select `.github/rulesets/main.json`.

**From the command line.**

```bash
gh api -X POST repos/uveshm003/encore/rulesets --input .github/rulesets/main.json
```

To update an existing ruleset, use its id — `gh api repos/uveshm003/encore/rulesets`
lists them — and `-X PUT repos/uveshm003/encore/rulesets/<id>`.

If the ruleset is edited in the interface, export it and commit the result, or
this file becomes fiction.

## What it enforces, and why

**No deletion, no force push** (`deletion`, `non_fast_forward`). The floor the
rest of this rests on. Released versions are tagged from `main`, and a rewritten
history silently invalidates every commit hash referenced from `CHANGELOG.md`,
an issue, or somebody's local clone.

**Changes arrive through a pull request** (`pull_request`), with
`required_approving_review_count` at `0`. There is one maintainer, so requiring
an approval would mean requiring a second person who does not exist. Zero still
buys the thing that matters: a pull request is what makes CI run against the
merge result, and it leaves a reviewable record of every change. Self-merging is
expected here, not a workaround.

`dismiss_stale_reviews_on_push` and `required_review_thread_resolution` matter
only once there is more than one person, and cost nothing before then.

`allowed_merge_methods` omits `merge`, so `main` stays linear. The history is
short and read often; a merge bubble per pull request would make
`git log --oneline` useless for seeing what actually happened.

**CI must be green** (`required_status_checks`). The contexts are the `name:`
of each job in [`ci.yml`](../.github/workflows/ci.yml), not the job id — GitHub
matches on the displayed name, so renaming a job in the workflow silently stops
enforcing it. The matrix job `Build ${{ matrix.target }}` is listed as its three
expansions.

The one worth naming is **`Release build requests no INTERNET permission`**.
NFR-OFF-01 is the app's central promise and the only thing that truly enforces
it is the absent Android permission. A dependency can add that permission
through manifest merging with no visible change in this repository, so the
check is required rather than advisory: a pull request that dissolves the
offline guarantee cannot reach `main` even if somebody clicks merge.

`strict_required_status_checks_policy` requires the branch to be current with
`main` before merging. It costs a rebase on a busy repository; at this size it
just means the checks tested what is actually about to land.

**`bypass_actors` is empty.** Nobody, including the repository owner, can push
straight to `main`. This is deliberate but not irreversible — an admin can
still edit or disable the ruleset in the interface, which is a considered act
that leaves an audit-log entry, unlike a `git push` at the wrong moment. If a
genuine emergency needs the door open, open it there and say so in the commit
that follows.

## When the checks change

Adding, renaming, or removing a job in `ci.yml` means editing the
`required_status_checks` list here and re-importing. A required check that no
longer reports leaves pull requests waiting forever on something that will
never arrive; a renamed one stops being enforced without any error at all.
