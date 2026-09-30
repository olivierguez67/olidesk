# Rollback Runbook

How to undo a bad merge, how to get a fix back out to devices, and what to do if a
release breaks the thing auto-update itself depends on. Written against this repo's
actual release mechanics, not generic advice — see the cross-references below if
something here goes stale.

## 1. Reverting a bad merge

### Before it reaches `origin/master`

Nothing has shipped yet, so this is ordinary git hygiene:

- **Only in your local worktree, not pushed anywhere:** `git reset --hard <commit-before-merge>`,
  or `git merge --abort` if you're still mid-merge and haven't committed it.
- **Pushed to a branch, but not yet merged into `master`:** fix the branch and force-push
  it (`git push --force-with-lease origin <branch>`), or just close the PR/delete the
  branch and start over. Nobody else's history depends on it yet.
- **A version bump + tag were prepared locally but not pushed:** `git tag -d vX.Y.Z`,
  then fix the branch, then bump/tag again. A local-only tag is free to throw away.

The one thing to check before any of the above: `git log --oneline origin/master..HEAD`
— if that list is longer than you expect, something you don't intend to discard may be
mixed in.

### After it reaches `origin/master`

Once it's pushed, other clones (and possibly already-running CI) have it — don't
force-push or rewrite `master`. Use `git revert` instead, which adds a new commit
undoing the change rather than erasing history:

```bash
# For a normal commit:
git revert <bad-commit-sha>

# For a merge commit specifically (revert needs to know which parent is "mainline"):
git revert -m 1 <bad-merge-commit-sha>
```

`-m 1` means "treat the first parent (master, the branch being merged into) as the
baseline, undo everything the second parent introduced." Push the revert commit
normally. If a tag was already cut from the bad state (see the "publish a rollback
release" section below) — **do not delete or move that tag**. Existing installs and
anyone who already downloaded that release may reference it; retagging the same
version number to point somewhere else is exactly the kind of silent rewrite that
breaks trust in tags. Cut a new, higher version instead.

If the bad merge already went through a full release cycle (tagged, built, published)
before anyone noticed, reverting the commit on `master` only stops the *next* release
from being bad — see the next section for getting the fix to devices that already
updated.

## 2. Publishing a rollback release

A "rollback" release is not republishing the old tag — it's a **new, higher version
number whose content matches the last-known-good state**. Two hard constraints force
this:

- **Android `versionCode` must strictly increase for the in-app updater to accept it**
  (confirmed this session: v1.4.57→93 was tested against v1.4.61→93's versionCode
  progression; Android's package installer rejects anything that isn't a strict
  increase, regardless of whether the *content* is what you actually want).
- **Devices that already updated to the bad version are looking for something newer
  than what they have**, not something older — pointing them "back" to the old tag
  wouldn't even surface as an available update.

Steps, using this repo's actual release mechanics:

1. Get `master` to the state you want published — normally that's "revert commit
   applied, `master` now matches the last-known-good behavior."
2. Bump all three version files together, to the same new number
   (`X.Y.(Z+1)` — the next patch number, not a reuse of the bad one):
   - `Cargo.toml` — the `version = "..."` line.
   - `Cargo.lock` — the `[[package]] name = "olidesk"` entry's own `version` line a
     few lines below it. **This one is easy to miss by hand** — it's caused a broken
     CI run at least once this session (`cargo build --locked` refuses to proceed if
     it's out of sync with `Cargo.toml`). Grep for it to confirm:
     `grep -A1 'name = "olidesk"' Cargo.lock`.
   - `flutter/pubspec.yaml` — the `version: X.Y.Z+N` line. Bump **both** the
     dotted version and the `+N` build number (Android's versionCode is the `+N`
     part — this is the number that must strictly increase, not the dotted version
     string).
   - The GitHub Actions workflows (`flutter-build.yml`, `client-build.yml`) do **not**
     need touching — they derive their own `VERSION` from `Cargo.toml` at run time
     (fixed this session; previously this was a fourth hand-maintained copy that
     silently drifted and caused a real incident — see the commit history around
     "Derive release VERSION from Cargo.toml").
3. Commit the three-file bump, then tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
4. Push both: `git push origin master` then `git push origin refs/tags/vX.Y.Z`
   (a bare `git push origin vX.Y.Z` has been ambiguous in this repo before when a
   same-named branch or old tag exists — use the fully-qualified ref).
5. **One tag triggers both release workflows automatically** — pushing `vX.Y.Z`
   fires `flutter-tag.yml` (the admin/`olidesk-*` build) *and* `client-build.yml`
   (the `olidesk-client-*` build) in parallel, since both match the same
   `v[0-9]+.[0-9]+.[0-9]+` tag pattern; they land in the same GitHub release,
   distinguished only by asset filename. No separate step needed for "both
   flavors."
6. Wait for CI. Historically ~50 minutes to ~1.5 hours for the full matrix
   (Windows/macOS/iOS/Android/Linux). The Android and Windows jobs are what actually
   matter for getting a fix to affected devices; don't block on an unrelated
   platform failure (e.g. this session hit an `x86_64-apple-darwin` vcpkg flake that
   had nothing to do with the actual fix being shipped).
7. Verify the published asset filenames actually say the new version number before
   telling anyone to update — `curl -s https://api.github.com/repos/<owner>/olidesk/releases/tags/vX.Y.Z | grep name`.
   This exact mismatch (tag said one version, assets said another) is what caused
   the original 404 incident this session traced back to.
8. All releases here are published with `prerelease: true` (both workflows) — the
   GitHub "latest release" API (`/releases/latest`) will **not** return them; you
   have to look at the full `/releases` list or the specific tag. Don't rely on
   "latest release" tooling to find what you just published.

**Do not delete the broken release/tag** unless you're certain nothing has installed
it yet (e.g. it was withdrawn within minutes of publishing, before any device could
have polled for updates) — once any device may have that version's assets cached or
referenced, deleting it only removes your own ability to inspect what shipped,
without helping anyone already affected.

## 3. If a release breaks the client's ability to connect

This is the scenario where auto-update can't save you, because auto-update itself
needs the same connectivity the release broke:

- Both the Android and Windows update paths require reaching **GitHub** (to check
  for and download the release) and, for Android, the app's own rendezvous/relay
  server connectivity isn't actually required for the update check itself — the
  in-app updater talks straight to GitHub via `OLIDESK_RELEASES_API`, independent
  of whether the user's remote-control connection works. **So a release that only
  breaks the remote-control connection (not general internet access) does not
  block auto-update from working** — affected devices should still be able to
  self-update normally once a fix is tagged. The genuinely unrecoverable case is
  narrower: internet/DNS/TLS breakage, or something that crashes the app before
  it reaches the update-check code path at all.
- If it's *that* narrow, genuinely-unrecoverable case: auto-update cannot reach
  the machine, full stop. Recovery is manual, per device:
  - **Android**: the last-known-good APK's direct GitHub release download URL,
    sent to whoever has physical or remote access to the device (email, chat,
    MDM push, USB). No connectivity is needed on the *server* side for this —
    only the affected device needs enough connectivity to fetch one URL, which
    is a much lower bar than "the app works."
  - **Windows**: same idea with the `.msi`/`.exe` asset — but Windows additionally
    has the actual Windows **service** (`sc create ... start= auto`, installed by
    the MSI) which may keep running with the old binary even if the *app*
    (tray/GUI process) can't function — check `sc query <app_name>` on the
    affected machine before assuming it's fully down.
  - Keep a **pinned, known-good version number** written down somewhere outside
    this repo (a password manager note, a pinned Slack message, whatever your
    team actually checks during an incident) — not just "the previous tag,"
    since figuring out which prior tag was actually good, under incident
    pressure, wastes exactly the time you don't have. Update that pin whenever
    you're confident a release is solid in the field, not just that it passed CI.
- **Prevention, for next time**: don't tag a release and let it fully auto-deploy to
  every device in one step. Install it manually on one or two machines first, confirm
  actual remote-control connectivity (not just that the app launches), *then* let the
  rest of the fleet pick it up via auto-update on their own schedule. Nothing in this
  repo's current release process enforces a staged rollout — this is a process
  discipline, not a technical gate, until the item in the next section changes that.

## 4. Can the updater verify a build starts successfully before discarding the old version?

**Not today, on either platform** — and it's worth being precise about why, since the
two platforms fail this in different ways:

- **Android**: a normal app update (outside Google Play's own staged-rollout
  infrastructure, which sideloaded/direct-APK installs don't get) simply replaces
  the old APK's bytes once install succeeds. There is no OS-level "install to a
  staging area, verify, then commit" step available to us — by the time
  `OpenFilex.open()`'s installer intent returns success, the old version is gone.
- **Windows (MSI)**: MSI *does* have native transactional rollback, but only for
  **installation-time** failures (the installer itself erroring out partway
  through file copy/registry writes) — restoring the previous file state in that
  case is automatic and already happens. It has no concept of "the install finished
  fine but the app is functionally broken" — that failure mode looks identical to
  MSI as a successful install.

So the safety net you want doesn't exist as a platform feature — it would have to be
something this app builds and owns. Sketch of what that would take, if you want it
built before the next upstream merge:

1. **A "did the last update actually work" flag**, written to local persistent
   storage (SharedPreferences on Android, the registry or a config file on Windows)
   *before* the update-triggering process exits, and cleared only after the new
   version has confirmed itself healthy on its next launch (e.g., successfully
   reached the rendezvous server, or simply survived N seconds without crashing —
   "crash-loop detection," a well-established pattern, not a novel one).
2. **A first-launch-after-update health check**, run once, that looks for that flag
   and, if the new version hasn't cleared it within some grace window (crashed
   immediately, or never got far enough to try), triggers the recovery path below
   instead of just continuing to boot into a broken state.
3. **The recovery path itself is another update, not a true rollback** — because
   versionCode can only move forward, "going back" means downloading and installing
   a *new* build (higher version number than the currently-broken one) whose
   *content* matches the last confirmed-good version. This means: whenever you
   publish a release, the previous good version's identity needs to be
   discoverable programmatically (e.g. the release notes or a small metadata file
   published alongside each release naming "last known good before this one"),
   not just known informally. Without that, an automatic rollback has nothing to
   roll back *to*.
4. This only helps future releases — it can't retroactively protect anyone already
   on a version built before this existed, for the same reason old builds can't be
   patched after the fact (covered in the earlier investigation this session: their
   update logic is frozen into the binary at build time).

This is a real, multi-piece feature (steps 1–3 each touch different parts of the
app and aren't trivial individually), not a one-line fix — worth scoping as its own
task rather than folding into whatever the next upstream merge is, if you want it
built. Say the word and I'll turn this into an actual implementation plan.
