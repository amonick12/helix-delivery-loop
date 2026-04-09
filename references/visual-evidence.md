# Visual Evidence Pipeline

## Screenshot Hosting

Screenshots are hosted as **GitHub Release assets** on the `screenshots` release tag. No branch needed.

```bash
# Upload a screenshot
gh release upload screenshots my-screenshot.png --repo amonick12/helix --clobber

# URL format (permanent, works in private repos for authenticated users):
# https://github.com/amonick12/helix/releases/download/screenshots/my-screenshot.png
```

**Naming convention:** `pr-<N>-<description>.png` (e.g., `pr-152-insights-patterns.png`)

**Image sizing:** All images in PR comments MUST use HTML `<img>` tags with `width="300"`:
```html
<img src="https://github.com/amonick12/helix/releases/download/screenshots/pr-152-after.png" width="300" />
```
Never use `![](url)` markdown for screenshots — it renders full-size and clutters the PR. The `verify-evidence.sh` script checks for `<img` tags as well as `![` syntax.

**Do NOT:**
- Commit screenshots to the repo or any branch
- Use the `screenshot-assets` branch (legacy — will be removed)
- Use `raw.githubusercontent.com` URLs (broken in private repos)

## Before/After Screenshots

### Process
1. Build `autodev` in worktree → boot sim → launch with fixture → capture screens the feature touches
2. Build feature branch in worktree → boot sim → launch with same fixture → capture identical screens
3. Upload to GitHub Release: `gh release upload screenshots pr-<N>-before.png pr-<N>-after.png --clobber`
4. Post side-by-side two-column markdown table to PR using release download URLs

### Rules
- Same view, same scroll position for before and after
- Cover ALL new states (empty + populated), not just one pair
- Use populated state with mocked data (`FAKE_FIXTURE=seeded_20_entries`), not just empty states
- Before/after must show EXACT same screen (never a parent view or different scroll)
- Text must be left-aligned, cells must expand to full container width

## Screen Recordings

### Source
XCUITests that exercise ALL new UI actions.

### Process
1. Write XCUITests in `helix-appUITests/`
2. Run with screen recording enabled via XCTAttachment
3. Trim dead time (no home screen waiting)
4. Keep animations ON for recordings (only OFF for automated speed runs)
5. Upload to GitHub Release: `gh release upload screenshots pr-<N>-recording.mov --clobber`
6. Post recording links in PR comments

### Rules
- idb is available for UI interaction alongside XCUITest and xcrun simctl
- Must exercise ALL new actions, not partial demos
- Only one simulator at a time (iPhone 17 Pro Codex)

## Cleanup

Releaser deletes release assets for merged PRs as part of post-merge cleanup:
```bash
gh release delete-asset screenshots pr-<N>-*.png --repo amonick12/helix
```
