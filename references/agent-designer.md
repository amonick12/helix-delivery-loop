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

```bash
gh issue comment <CARD_NUMBER> --body "## Design Mockup (Helix Dark)

<img src=\"$SCREENSHOT_URL\" width=\"400\">

### Design Notes
<your notes here>"
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
