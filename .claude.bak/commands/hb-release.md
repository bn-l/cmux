---
description: Execute a full Homebrew release for cmux.
disable-model-invocation: true
---

## Homebrew Release

Execute a full Homebrew release for cmux. No arguments needed — version bump level is determined automatically from commit history.

### Step 1: Project type

This is a **macOS app (cask)** with a local build.

- Version source: `MARKETING_VERSION` in `GhosttyTabs.xcodeproj/project.pbxproj`
- Build: `just release`
- Artifact: DMG (built locally)
- Tap file: `/Users/bml/projects/misc-projects/homebrew-tap/Casks/cmux.rb`

### Step 2: Ensure clean working tree

Run `git status`. All changes must be committed (untracked files are fine). If there are uncommitted changes, stop and tell me.

Then sync tags from the remote so we have a complete picture: `git fetch --tags --force`. The `--force` flag ensures local tags that diverge from remote are overwritten.

### Step 3: Determine version bump

1. Find the most recent version tag (e.g. `v1.2.3`) with `git tag --sort=-v:refname`. **The tag is the source of truth for the current released version — ignore what the manifest file says**, as it may have been bumped by a previous partial release attempt.
2. Read commits since that tag: `git log <last-tag>..HEAD --oneline`
3. **Exclude version-bump housekeeping commits** — ignore any commits matching `hk: bump version` or `hk: bump build number` when determining the bump level. These are artifacts of prior release attempts, not feature/fix work.
4. Apply conventional commit rules to the remaining commits (highest wins):

- `BREAKING CHANGE` anywhere in message, or `!:` (e.g. `feat!:`) → **major**
- `feat:` or `feat(...):` → **minor**
- Anything else (`fix:`, `hk:`, `docs:`, etc.) → **patch**

5. Compute the new version from the tag version + bump level.
6. **Collision check**: Verify no tag already exists for the computed version (`git tag -l "v<NEW_VERSION>"`). If one does exist, use that tag as the new baseline and repeat from sub-step 2. Continue until you land on an unused version.
7. If the project already shows the correct new version (from a previous partial attempt), do NOT re-bump it — just confirm it's correct and skip Step 4.
8. Show me what you determined: current version (from tag), bump level, new version, and the non-housekeeping commits that informed the decision. Then proceed.

### Step 4: Bump version

Run `./scripts/bump-version.sh <VERSION>` — this updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number) in the Xcode project.

Commit: `git add GhosttyTabs.xcodeproj/project.pbxproj && git commit -m "hk: bump version to <VERSION>"`

### Step 5: Build and publish

1. Push to remote: `git push origin main`
2. Tag and push tag: `git tag v<VERSION> && git push origin v<VERSION>`
3. Run `just release` — this builds the app, creates a DMG, creates a GitHub release, uploads the DMG and daemon binary, and prints the SHA256. Capture the SHA256 from the output.

### Step 6: Update the Homebrew tap

Edit `/Users/bml/projects/misc-projects/homebrew-tap/Casks/cmux.rb`. Update `version` and `sha256`.

Then commit and push:
```
cd /Users/bml/projects/misc-projects/homebrew-tap
git add Casks/cmux.rb && git commit -m "cmux <VERSION>" && git push origin main
```

Never include a Co-Authored-By trailer in any commit message.

### Step 7: Verify

```
brew update && brew upgrade --cask bn-l/tap/cmux && brew info bn-l/tap/cmux
```

You are not finished until the installed version matches the new version.
