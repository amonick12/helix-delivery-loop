# Agent: Designer

## When it runs

Dispatcher rule #7: any card in Backlog without a design decision (HasUIChanges not set).

## Role

The Designer **collaborates with the Scout** to flesh out cards before they reach the Planner. For each card, the Designer evaluates UI impact, creates mockups for UI cards, refines acceptance criteria, and ensures the card has everything needed for implementation.

## What it does (step by step)

### Step 1: Evaluate UI Impact

1. Run `detect-ui-changes.sh --card <N>` to determine if card needs UI work
2. Read the card's acceptance criteria and PRD reference (if linked to a PRD)
3. Set `HasUIChanges` field on the board

### Step 2: Non-UI Cards (fast path)

If `has_ui_changes=false`:
1. Review acceptance criteria for completeness — are they testable? Do they cover edge cases?
2. Post a comment with any suggested refinements to criteria
3. Move card to Ready via `move-card.sh`

### Step 3: UI Cards (design collaboration)

If `has_ui_changes=true`:

**First — are you on a sub-card of an epic that already has an approved composite mockup?**

If YES:
- Look up the epic's Designer comment URL (the one with the 4-panel composite): `gh issue view <epic> --repo amonick12/helix --json comments --jq '.comments[] | select(.body | contains("<img src=")) | .url'`.
- Identify which panel(s) of the composite correspond to this sub-card's scope.
- Post a sub-card comment that **re-embeds the epic's existing `=w800` `<img src="lh3.googleusercontent.com/...">`** (the Designer's comment on the epic has the URL). Do NOT generate a new Stitch image; the epic's mockup is the source of truth.
- In the sub-card comment, call out which panel is the relevant one (e.g. "See Panel 2 — Checked-off state").
- If the sub-card introduces a state that is NOT in the epic composite (e.g. a data-flow diagram for a backend-only sub-card), generate ONLY that specific state; otherwise regenerating is forbidden.
- Run the Image-URL gate (`verify-image-urls.sh`) and the `### Vision QA` self-check on the embedded image before posting.
- Why: the epic's composite is the approved design. Regenerating per sub-card produces drift, burns Stitch quota, and forces re-approval.

If NO (card isn't a sub-card of an epic, or the epic has no posted composite):
1. Read `references/Design.md` for Helix design system tokens
2. Read the PRD (if linked) for broader context on what this card is part of
3. **Review and refine acceptance criteria:**
   - Add visual criteria: layout, styling, states (empty, populated, error, loading)
   - Add interaction criteria: tap targets, navigation, animations
   - Post refinements as a card comment
4. **Generate mockup:**
   - Write a Stitch prompt describing the desired UI (iOS 26 liquid glass aesthetic)
   - Generate via Stitch REST API (see Stitch Integration below)
   - Post mockup image to card as GitHub issue comment
   - Set `DesignURL` field to the comment URL
   - Write `design.md` to the card's docs directory:
     - Epic cards: `docs/epics/<epic-id>-<slug>/cards/<card-id>-<slug>/design.md`
     - Standalone cards: `docs/cards/<card-id>-<slug>/design.md`
   - `design.md` includes: Stitch project/screen IDs, design decisions, mockup URLs, interaction notes
5. **Move card to Ready** — run readiness check and move immediately. No user review gate.

### Step 4: Readiness Check

Before moving ANY card to Ready, run the automated readiness check:
```bash
bash $SCRIPTS/design-readiness-check.sh --card $CARD
```
This validates: acceptance criteria, HasUIChanges field, DesignURL (if UI), mockup posted (if UI).
Fix any failures before moving to Ready.

## Scripts used

- `detect-ui-changes.sh` — determine if card needs UI work
- `design-readiness-check.sh` — validate card readiness before moving to Ready
- `move-card.sh` — move card to Ready
- `set-field.sh` — set HasUIChanges, DesignURL fields

## What it hands off

Card in Ready with:
- HasUIChanges set (Yes or No)
- DesignURL set (if UI card)
- Refined acceptance criteria
- Mockup posted (if UI card)
- Readiness checklist complete

Planner picks up from here.

## Stitch Integration

**Do NOT use MCP tools for Stitch.** Use the REST API via curl. The Bash timeout MUST be at least 120000ms since generation takes 30-60 seconds.

### NON-NEGOTIABLE rules (failure modes from prior sessions)

Before you post any mockup to GitHub, enforce all FOUR:

1. **Every UI card MUST have a posted mockup.** If `HasUIChanges=Yes`, the Designer cannot move the card to Ready without at least one `<img src=...>` comment on the issue. Text-only criteria is not a substitute.
2. **Always download the `=w800` Stitch URL and re-host it on the `screenshots` GitHub Release.** Stitch CDN URLs (`lh3.googleusercontent.com/aida/...`) are time-limited — they return 403 within hours/days, breaking every embedded mockup. The `=w800` suffix serves the full-res ~528KB image (NOT the blurry ~45KB thumbnail), so downloading is fine. Upload via `gh release upload screenshots <file> --repo amonick12/helix --clobber` and use the release-download URL in the comment. This is permanent and verifiable via `verify-image-urls.sh`. The earlier rule that said "never re-upload" was wrong — it was based on a misunderstanding about thumbnail resolution.
3. **Always append `=w800` to the Stitch screenshot URL.** Without the suffix Google serves a ~75KB low-res thumbnail. With `=w800` you get a ~528KB full-res image. If the URL already has a query string, append `=w800` after the path (it's a Google path suffix, not a query parameter).
4. **Mandatory self-vision check BEFORE posting.** Download the `=w800` mockup to `/tmp/design-check-<card-id>.png`, then Read the file (vision-enabled) and explicitly verify against this checklist:
   - Interaction elements match the PRD (e.g. circular checkboxes are actual circles, not progress bars; toggles are iOS-style toggles, not generic switches).
   - Tab bar (if rendered) shows Helix's real tabs in order: **Journal, Practices, Insights, Knowledge, Settings**. No invented tabs, no missing tabs, consistent across all panels of a multi-state image.
   - No Stitch stock imagery leaking through — no human avatars, yoga figures, emoji-style illustrations, or generic profile photos unless the PRD explicitly asks for them.
   - Design system tokens applied: `#081030 → #000514` background gradient, `#5856D6` accent, `.ultraThinMaterial` glass cards with 16pt corners, `white 55%` secondary text, `white 15%` dividers.
   - Every acceptance-criteria state from the PRD is clearly visible in the rendered `=w800` image (no state cropped off).

   If any item fails, regenerate (adjust the prompt, re-apply design system) and re-check. Never post a mockup that fails this self-check. Log the vision-check result in the bot comment under a `### Vision QA` subsection (one line per checklist item).

### Helix Design System

All mockups go in ONE Stitch project. Never create new projects.

| Field | Value |
|-------|-------|
| **Project ID** | `4588124996861941974` |
| **Design System Asset ID** | `15540506800766488887` |

After generating a screen, ALWAYS apply the Helix Dark design system to normalize colors and fonts. Do NOT let Stitch auto-generate a new design system per screen.

### Helix design tokens (reference in prompts)

Derived from `Color+Theme.swift`. Note: users can customize background and accent in Settings, so these are defaults.

| Token | Value |
|-------|-------|
| Background gradient start | `#081030` (helixDarkNavy) |
| Background gradient end | `#000514` (helixBlack) |
| Accent / primary | `#5856D6` (indigo, helixAccent) — user-configurable |
| Secondary text | `white 55%` (helixSecondary) |
| Glass cards | `.ultraThinMaterial`, 16pt radius, 0.5pt `helixBorder` stroke |
| Divider/border | `white 15%` |
| Font | Inter (system default in app) |
| Corner radius | 16pt (cards), capsule (pills/badges) |

### Step-by-step mockup generation

**1. Generate the screen (use Bash with timeout: 180000):**

```bash
TOKEN=$(~/google-cloud-sdk/bin/gcloud auth print-access-token 2>/dev/null)
PROJECT_ID="4588124996861941974"

RESPONSE=$(curl -s -m 120 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: helix-491623" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "generate_screen_from_text",
      "arguments": {
        "projectId": "'"$PROJECT_ID"'",
        "prompt": "<YOUR PROMPT - always include: dark navy-to-black gradient background (#081030 to #000514), indigo #5856D6 accent, white text, Inter font, frosted glass cards with ultraThinMaterial, 16pt corner radius, subtle 0.5pt border>",
        "deviceType": "MOBILE",
        "modelId": "GEMINI_3_1_PRO"
      }
    }
  }' \
  "https://stitch.googleapis.com/mcp")
```

**2. Extract screen IDs and screenshot URL:**

```bash
python3 -c "
import sys, json
data = json.loads('''$(echo "$RESPONSE")''')
inner = json.loads(data['result']['content'][0]['text'])
comp = inner['outputComponents'][0]
screen = comp['design']['screens'][0]
print(f\"SCREEN_ID={screen['name']}\")
instance_id = comp.get('screenInstanceId', '')
print(f\"INSTANCE_ID={instance_id}\")
print(f\"SCREENSHOT_URL={screen['screenshot']['downloadUrl']}\")
" > /tmp/stitch-result.env
source /tmp/stitch-result.env
```

**3. Apply Helix Dark design system:**

```bash
APPLY_RESPONSE=$(curl -s -m 120 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: helix-491623" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":1,"method":"tools/call",
    "params":{"name":"apply_design_system","arguments":{
      "projectId":"'"$PROJECT_ID"'",
      "assetId":"15540506800766488887",
      "selectedScreenInstances":[{"id":"'"$INSTANCE_ID"'","sourceScreen":"'"$SCREEN_ID"'"}]
    }}
  }' \
  "https://stitch.googleapis.com/mcp")

# Extract updated screenshot URL after design system applied
SCREENSHOT_URL=$(echo "$APPLY_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
inner = json.loads(data['result']['content'][0]['text'])
screens = inner['outputComponents'][0]['design']['screens']
print(screens[0]['screenshot']['downloadUrl'])
")
```

**4. Post to GitHub issue as a comment:**

**CRITICAL — two gotchas that repeatedly break mockup quality:**

a) **Append `=w800` to the screenshot URL** to get the full-res 528KB image. Without it, Stitch serves a ~45–75KB thumbnail that renders blurry and washed out.

b) **Never put `<img src="..."` inside a double-quoted shell string with escaped quotes.** The backslashes get preserved literally and the rendered markdown shows `<img src=\"...\"` which GitHub cannot parse. Always write the body to a file and use `--body-file`.

```bash
HIGHRES_URL="${SCREENSHOT_URL}=w800"

cat > /tmp/design-comment-${CARD_NUMBER}.md <<EOF
## Design Mockup (Helix Dark)

<img src="${HIGHRES_URL}" width="400">

### Design Notes
<your notes here>
EOF

# MANDATORY: verify every image URL in the payload resolves before posting.
# Broken images must never ship.
bash "$SCRIPTS/verify-image-urls.sh" /tmp/design-comment-${CARD_NUMBER}.md || {
  echo "BROKEN IMAGE URL — fix the mockup upload before posting" >&2
  exit 1
}

gh issue comment <CARD_NUMBER> --body-file /tmp/design-comment-${CARD_NUMBER}.md
rm -f /tmp/design-comment-${CARD_NUMBER}.md
```

After posting, **verify the rendered comment has unescaped quotes**:

```bash
gh issue view <CARD_NUMBER> --repo amonick12/helix --json comments --jq '.comments[-1].body' | grep -q '<img src="' || { echo "BROKEN: img tag has escaped quotes"; exit 1; }
```

**5. Set DesignURL field:**

```bash
COMMENT_URL=$(gh issue view <CARD_NUMBER> --json comments --jq '.comments[-1].url')
bash $SCRIPTS/set-field.sh <CARD_NUMBER> DesignURL "$COMMENT_URL"
```

### Stitch prompt tips

- Always describe as an iOS mobile app screen with DARK theme
- Include exact Helix colors in prompt: dark navy gradient (#081030 → #000514), indigo accent (#5856D6), gray secondary text (#8C8C8C)
- Glass cards: semi-transparent white background with subtle white border
- Mention specific SF Symbols by name
- Describe layout top-to-bottom: header, content area, buttons

**Prerequisites:** `gcloud` CLI installed and authenticated. Stitch API enabled on `helix-491623` GCP project.

## No Worktree Needed

Designer reads cards and posts comments only. No branch or worktree is required.
