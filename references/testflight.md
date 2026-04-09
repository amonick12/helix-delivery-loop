# TestFlight Integration

## When to Upload

- Only for cards with `HasUIChanges: Yes`
- **Owner: Releaser** — runs step 1b (before merge) after `user-approved` label is applied
- Non-UI changes (bug fixes, refactors, backend) skip TestFlight entirely

## Build Numbering

- Deterministic formula: `(issue_number * 100) + loop_count`
- No shared counter or state file needed
- Computed by `build_number()` in `config.sh`

## Upload Process

1. Compute build number: `build_number <issue_number> <loop_count>`
2. Run: `./devtools/ios-agent/testflight-upload.sh --build-number <N>`
3. Required env vars: `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_PATH`
4. On success: add "## TestFlight" section to PR body with build number, link, and "What to Test" list from acceptance criteria
5. On failure: log error and continue — do not block the merge

## PR Body Format

Add as a section in the PR description:

```markdown
## TestFlight

- **Build:** `<N>`
- **Link:** [TestFlight](https://testflight.apple.com/join/...)
- Uploaded: `<timestamp>`

### What to Test
- [ ] <acceptance criterion 1>
- [ ] <acceptance criterion 2>

Build is processing in App Store Connect. Available in TestFlight within ~15 minutes.
```

## Prerequisites

- App Store Connect API key configured in `.claude/settings.local.json`
- `ASC_API_KEY_PATH` pointing to `.p8` key file
- Signing certificates and provisioning profiles available
- `ExportOptions.plist` at `devtools/ios-agent/ExportOptions.plist`
