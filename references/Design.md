# Helix Design System

Reference for the Designer agent. Designs are written by the Designer (Opus 4.7) as **real SwiftUI views** in `helix-app/PreviewHost/Mockups/` using the tokens below. Mockups are screenshot from the simulator — they cannot drift from the shipping app because they *are* the app's design system.

The tokens below mirror `Color+Theme.swift` and `HelixDesignSystem.glassCard()`. Update both whenever a token changes.

## Platform

- iOS 26 with liquid glass material system
- SwiftUI native components
- Dark theme only (no light mode)

## Background Themes (user-configurable in Settings)

Default is **Ocean**; mockups should always render Ocean unless a card specifies otherwise.

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
| `.glassCapsule()` | `.ultraThinMaterial` capsule + 0.5pt border | Tags / badges |

## Typography

- All text uses `helixFont` modifier tied to `SettingsService.appFontStyle`.
- Default font: Inter (system).
- Semantic styles: `.headline`, `.subheadline`, `.body`, `.caption`, `.caption2`.
- Weight variants: `.weight(.semibold)`, `.weight(.bold)`.
- Never hardcode fonts — always use `helixFont`.

## Component Patterns

### Section cards
`.ultraThinMaterial` background, 16pt corner radius, `helixBorder` 0.5pt stroke, 16px internal padding.

### Tag pills
Glass capsule, caption text, tint-colored icon + white text.

### Stat badges
Vertical stack: icon (tint), value (white, semibold), label (secondary, caption2).

### Disclosure groups
Chevron-animated expand/collapse, indigo accent on chevron and icon.

### Tab bar
**Six tabs** in this order, with these exact SF Symbols (from `helix-app/App/HelixTabView.swift`):
1. **Today** — `house.fill`
2. **Journal** — `book`
3. **Practices** — `figure.mind.and.body`
4. **Insights** — `chart.line.uptrend.xyaxis`
5. **Knowledge** — `books.vertical`
6. **Settings** — `gearshape`

The tab bar itself is **iOS 26 liquid glass** (`.tabViewStyle(.sidebarAdaptable)` plus the system glass material — translucent over the content, with the same refraction the cards have). Mockups must render the bar as glass, not opaque, not a solid stroke.

### Navigation
Large title style, top-right profile/menu button.

### Lists
Card-based rows (not plain `List` rows). Each card is a glass surface with internal padding.

## Layout

- Horizontal padding: 16px
- Card spacing: 12–16px
- Section spacing: 20–24px
- Safe area respected on all edges

## iOS 26 Liquid Glass

- Use `Glass` material for card surfaces
- Subtle light refraction on overlapping elements
- Translucent backgrounds — never opaque solids on cards
- System blur materials where appropriate

## Existing Screens (context for Claude Design prompts)

### Journal Tab
List of journal entry cards with title, subtitle, date, tag pills. Floating compose button (bottom-right). Tag filter bar (horizontal scroll, top).

### Journal Entry Detail
Full entry text, AI-generated insights section, cognition insights (patterns, connected entries, themes). Chat interface at the bottom for journal conversations.

### Insights Tab
Weekly Review card (collapsible, stat badges). Insight Report with mood trend, themes, recommended prompts. Cognition Activity Feed. "Ask Helix" floating button.

### Practices Tab
Practice cards with title, category icon, duration. Filter by category.

### Knowledge Tab
Domain / module / deep-dive hierarchy. Article cards with bookmarking.

### Settings Tab
Grouped settings rows. Data export, reset, font selection, AI provider config.

## When to update this file

- A new color token, glass material, or component pattern lands in `Color+Theme.swift` or the design system extensions.
- A new top-level screen is introduced.
- A theme is added/removed in Settings.

The Designer reads this file as authoritative reference when authoring SwiftUI mockup views. Keep the table values identical to the live `Color+Theme.swift` constants.
