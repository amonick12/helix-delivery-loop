# Vision QA Prompt (for orchestrator-spawned subagents)

This is the prompt the orchestrator hands to a fresh subagent when Stage A vision QA fires. The subagent's only job: Read each panel image with vision and return strict JSON.

## Fetching panel images (private repo)

The Helix repo is private. Public `https://github.com/.../releases/download/...` URLs return 404 to any client without GitHub auth (including the `Read` tool's HTTP fetcher). **Do NOT pass the release URL directly to `Read`.** Instead, download each asset with the authenticated `gh` CLI first, then `Read` the local file:

```bash
mkdir -p /tmp/vqa-<card>
gh release download screenshots --repo amonick12/helix \
  --pattern 'design-<card>-*.png' \
  --dir /tmp/vqa-<card> --clobber
ls /tmp/vqa-<card>/
```

Then pass the local `/tmp/vqa-<card>/*.png` paths to `Read`. If a panel name in the queue's `screenshots[]` doesn't appear in the downloaded directory, that's an `image fetch failed: not on release` failure for that panel.

## Helix Quality Bar (panels must pass all of these)

**Required tokens:**
- Background: Ocean gradient `#081030 → #000514`
- Accent: indigo `#5856D6`
- Cards: `.ultraThinMaterial` glass, 16pt corner radius, 0.5pt border
- Secondary text: white 55%
- Border / divider: white 15%
- Font: Inter
- Tab bar (when shown): exactly **6 tabs** in order — **Today** (`house.fill`), **Journal** (`book`), **Practices** (`figure.mind.and.body`), **Insights** (`chart.line.uptrend.xyaxis`), **Knowledge** (`books.vertical`), **Settings** (`gearshape`). No extras, no missing, no rename. The tab bar bar itself is **liquid glass** (translucent material over the content with the same refraction the cards use); a solid-fill or stroke-only tab bar fails.

**Entry-point integration (required for new features):**
- For a feature that adds a new interpretive / interactive surface, **at least one panel must show the entry point in the existing app** — i.e., where a user starting from the current shipping UX (Today, a journal entry, a practice card, an insight surface) would discover and tap into the new feature. Mockups that only show the *destination* surfaces fail this check. Acceptable forms: a callout in the entry-point screen, a contextual menu item, an affordance in the existing detail view, a Today rail entry. Without this, the design has no anchor in the live app.

**Forbidden patterns (auto-fail):**
- Stock human/yoga/avatar/lotus imagery
- Centered hero block with single illustration + lone CTA (generic AI-app aesthetic)
- Placeholder text: "Lorem ipsum", "Sample title", "Your text here"
- Opaque solid card backgrounds (cards must be glass/translucent)
- Light mode anywhere
- Microcopy: "Powered by AI", "Smart …", "Magic …", "Let AI help you", "Intelligent …"
- Acceptance-criteria states cropped or missing
- Decorative-only icons (every icon must label or act)

**Density / rhythm:**
- One primary action per screen (everything else demoted to secondary/tertiary)
- 4pt grid (margins / paddings / gaps are multiples of 4)
- Generous breathing room — crowded cards fail
- No two same-priority CTAs in the same row

**Sample data:**
- Real Helix-domain content (dreams, archetypes, kundalini, shadow, integration, symbolic content)
- Not "Test entry 1" / "Lorem ipsum" / generic to-do list items

## Image-load failure rule (auto-fail)

If any URL **fails to load** (404, network error, image too small to read, redirect to a non-image), include it in `panels[]` with `pass: false` and the failure reason `"image fetch failed: <reason>"`. **Do NOT skip a URL that doesn't load** — that would silently pass-by-default. The cron checks `all_pass` strictly.

## Output schema (strict)

```json
{
  "all_pass": true,
  "panels": [
    {
      "url": "https://github.com/.../design-148-empty.png",
      "pass": true,
      "failures": []
    }
  ]
}
```

`all_pass` is `true` only when every entry in `panels[]` has `pass: true`. A single failed image → `all_pass: false`.

`failures` is an array of short failure-reason strings (e.g., `"tab bar shows Profile instead of Knowledge"`, `"placeholder text 'Lorem ipsum' in card 2"`, `"image fetch failed: 404"`).

JSON only — no markdown, no prose, no preamble.
