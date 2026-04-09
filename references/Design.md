# Helix Design System

Reference for generating UI mockups via Google Stitch. Agents include relevant sections in Stitch prompts to ensure generated mockups match the Helix app.

## Stitch Project

All mockups go in ONE project. Always apply the design system after generating.

| Field | Value |
|-------|-------|
| **Project ID** | `4588124996861941974` |
| **Design System Asset ID** | `15540506800766488887` |
| **Design System Name** | Helix Dark |

## Platform
- iOS 26 with liquid glass material system
- SwiftUI native components
- Dark theme only (no light mode)

## Background Themes (user-configurable in Settings)
The default is **Ocean** but users pick their theme. Use Ocean for mockups.

| Theme | Top | Bottom |
|-------|-----|--------|
| Ocean (default) | `#081030` | `#000514` |
| Twilight Indigo | `#141A33` | `#32275F` |
| Aurora Teal | `#0A2421` | `#1F4B46` |
| Nightfall Slate | `#171B22` | `#2B313D` |
| Dusk Plum | `#22182F` | `#52355A` |
| Forest Pine | `#0E221B` | `#214436` |
| Ember Night | `#2A1A1C` | `#5A3431` |

## Color Tokens (from Color+Theme.swift)
| Token | Value | Usage |
|-------|-------|-------|
| `Color.helixAccent` | `Color.indigo` ≈ `#5856D6` | Primary accent / interactive |
| `Color.helixSecondary` | `white 55%` | Secondary text |
| `Color.helixBorder` | `white 15%` | Borders and dividers |
| `.darkGradientBackground()` | Theme gradient | App-wide background |
| `.glassCard()` | `.ultraThinMaterial` + 16pt radius + 0.5pt border | Card surfaces |
| `.glassCapsule()` | `.ultraThinMaterial` capsule + 0.5pt border | Tags/badges |

## Typography
- All text uses `helixFont` modifier tied to `SettingsService.appFontStyle`
- Default font: Inter (system)
- Semantic styles: `.headline`, `.subheadline`, `.body`, `.caption`, `.caption2`
- Weight variants: `.weight(.semibold)`, `.weight(.bold)`
- Never hardcode fonts — always use the `helixFont` system

## Component Patterns

### Section Cards
`.ultraThinMaterial` background, 16pt corner radius, `helixBorder` 0.5pt stroke, 16px internal padding.

### Tag Pills
Glass capsule, caption text, tint-colored icon + white text.

### Stat Badges
Vertical stack: icon (tint), value (white, semibold), label (secondary, caption2).

### Disclosure Groups
Chevron-animated expand/collapse, indigo accent color on chevron and icon.

### Tab Bar
5 tabs: Journal, Practices, Insights, Knowledge, Settings. SF Symbols icons.

### Navigation
Large title style, top-right profile/menu button.

### Lists
Card-based rows (not plain List rows). Each card is a glass surface with internal padding.

## Layout
- Horizontal padding: 16px standard
- Card spacing: 12-16px between cards
- Section spacing: 20-24px between sections
- Safe area respected on all edges

## iOS 26 Liquid Glass
- Use `Glass` material for card surfaces
- Subtle light refraction effect on overlapping elements
- Translucent backgrounds that show depth
- No opaque solid backgrounds on cards — always glass/translucent
- System blur materials where appropriate

## Stitch Prompt Template

When generating mockups, agents MUST structure prompts like:

```
Generate an iOS 26 mobile app screen mockup for [screen name].

Design system:
- Dark theme: Ocean gradient background (#081030 → #000514)
- Glass cards: ultra-thin material (frosted glass), 16pt corner radius, subtle 0.5pt border
- Accent color: indigo #5856D6
- Secondary text: white 55%
- Font: Inter
- 16px horizontal padding, 12px card spacing
- iOS 26 liquid glass aesthetic

Screen content:
[describe what the screen shows — sections, cards, data, interactions]

The mockup should look like a native iOS 26 app with Apple's liquid glass material system. Cards should have frosted translucent glass surfaces, not opaque backgrounds.
```

After generating, ALWAYS apply the Helix Dark design system (asset `15540506800766488887`) to normalize colors and fonts.

## Existing Screens (for context in prompts)

### Journal Tab
- List of journal entry cards with title, subtitle, date, tag pills
- Floating compose button (bottom-right)
- Tag filter bar (horizontal scroll, top)

### Journal Entry Detail
- Full entry text, AI-generated insights section, cognition insights (patterns, connected entries, themes)
- Chat interface at bottom for journal conversations

### Insights Tab
- Weekly Review card (collapsible, stat badges)
- Insight Report with mood trend, themes, recommended prompts
- Cognition Activity Feed
- "Ask Helix" floating button

### Practices Tab
- Practice cards with title, category icon, duration
- Filter by category

### Knowledge Tab
- Domain/module/deep-dive hierarchy
- Article cards with bookmarking

### Settings Tab
- Grouped settings rows
- Data export, reset, font selection, AI provider config
