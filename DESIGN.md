---
name: AI Notebook
description: A luminous product stage for private, local-first research.
colors:
  ink: "#17171C"
  night: "#0C0C12"
  paper: "#F7F8FC"
  surface: "#FFFFFF"
  muted: "#686A73"
  line: "#D9DCE6"
  notebook-blue: "#316BE8"
  notebook-violet: "#7045E8"
  privacy-mint: "#1D815B"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Display, Helvetica Neue, sans-serif"
    fontSize: "clamp(3.5rem, 9vw, 7.75rem)"
    fontWeight: 700
    lineHeight: 0.92
    letterSpacing: "-0.065em"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Display, Helvetica Neue, sans-serif"
    fontSize: "clamp(2.5rem, 6vw, 5.5rem)"
    fontWeight: 700
    lineHeight: 0.98
    letterSpacing: "-0.055em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "1.125rem"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  button: "999px"
  media: "28px"
  panel: "32px"
spacing:
  xs: "8px"
  sm: "16px"
  md: "24px"
  lg: "48px"
  xl: "96px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.surface}"
    rounded: "{rounded.button}"
    padding: "14px 22px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    padding: "14px 22px"
---

# Design System: AI Notebook

## 1. Overview

**Creative North Star: "The Luminous Private Workspace"**

AI Notebook is presented as a luminous native object emerging from a dark, private workspace. Dramatic product-scale typography, cinematic depth, and interactive real screenshots create a modern product narrative; cool paper sections provide deliberate moments of contrast and calm.

The system rejects both generic AI-startup spectacle and documentation-shaped marketing. It does not turn README headings into page sections, enumerate features as the main story, use gradient headlines, or repeat identical cards. Product interaction, atmosphere, and concise language carry the story.

**Key Characteristics:**

- Oversized, tightly tracked product typography
- A deep product-theater opening balanced by cool paper sections
- Real application screenshots presented as physical desktop objects
- Interactive product views instead of static feature lists
- Calm, brief motion that fully respects reduced-motion settings

## 2. Colors

Night establishes privacy and product theater; cool paper creates contrast while Notebook Blue and Violet provide luminous depth.

### Primary

- **Notebook Blue** (#316BE8): Primary product accent, interactive links, and the start of the app-icon field.
- **Notebook Violet** (#7045E8): Supporting identity color used sparingly in large atmospheric fields.

### Secondary

- **Privacy Mint** (#1D815B): Privacy confirmation and local-status details only.

### Neutral

- **Ink** (#17171C): Main headings, navigation, and dark calls to action.
- **Night** (#0C0C12): Hero, final call to action, and cinematic product framing.
- **Paper** (#F7F8FC): Default page background, tinted toward the product blue.
- **Surface** (#FFFFFF): Screenshot frames and high-contrast controls.
- **Muted** (#686A73): Supporting copy and metadata.
- **Line** (#D9DCE6): Quiet separators and control outlines.

### Named Rules

**The Luminous Field Rule.** Blue and violet create atmosphere behind the product and privacy story, never gradient text or decorative component chrome.

## 3. Typography

**Display Font:** SF Pro Display via the native Apple system stack, with Helvetica Neue fallback
**Body Font:** SF Pro Text via the native Apple system stack, with Helvetica Neue fallback

**Character:** Native, direct, and finely engineered. One system family keeps the page focused while dramatic scale and weight provide hierarchy.

### Hierarchy

- **Display** (700, `clamp(3.5rem, 9vw, 7.75rem)`, 0.92): Hero statement only.
- **Headline** (700, `clamp(2.5rem, 6vw, 5.5rem)`, 0.98): Major narrative turns.
- **Title** (650, `clamp(1.5rem, 3vw, 2.5rem)`, 1.08): Feature and platform titles.
- **Body** (400, `1.125rem`, 1.55): Explanatory copy, capped at 68 characters.
- **Label** (600, `0.8rem`, 0.02em): Short metadata and status labels; sentence case by default.

### Named Rules

**The One Sentence Rule.** Every major section earns one concise, high-impact sentence before any supporting detail.

## 4. Elevation

The page is flat by default, but the real product receives cinematic depth against the dark hero and gallery stage. Broad shifts between Night, Paper, and privacy blue establish the narrative without stacking cards.

### Shadow Vocabulary

- **Product Float** (`0 40px 100px rgba(26, 31, 52, 0.18), 0 8px 24px rgba(26, 31, 52, 0.10)`): Large application screenshots only.
- **Control Lift** (`0 8px 24px rgba(26, 31, 52, 0.10)`): Hovered primary controls and the compact navigation.

### Named Rules

**The Evidence Gets Depth Rule.** The strongest shadow belongs to a real screenshot, never a decorative container.

## 5. Components

### Buttons

- **Shape:** Full capsule (`999px`) with a minimum 44px hit area.
- **Primary:** Ink background, Surface text, 14px by 22px padding.
- **Hover / Focus:** Small translate transform, clear outline, and fast ease-out transition.
- **Secondary:** Surface background with a Line border; no transparent glass effect.

### Chips

- **Style:** Small tinted background, compact status dot, and sentence-case label.
- **State:** Informational only; interactive chips receive the same focus treatment as buttons.

### Cards / Containers

- **Corner Style:** 28px for media, 32px for rare content panels.
- **Background:** Surface or a purposeful full-section tint.
- **Shadow Strategy:** Flat unless the container represents the application window.
- **Border:** One-pixel Line border where separation is necessary.
- **Internal Padding:** Fluid, typically 24px to 48px.

### Inputs / Fields

- **Style:** Surface background, one-pixel Line border, 14px radius.
- **Focus:** Two-pixel Notebook Blue outline with visible offset.
- **Error / Disabled:** Errors pair color with text; disabled controls retain readable contrast.

### Navigation

Compact, dark, and sticky with restrained translucency to preserve context while scrolling. Links are sentence case; the mobile layout reduces to brand, download, and menu toggle.

### Product Window

A real screenshot sits inside a thin, softly rounded frame with a subtle top bar. It may float gently on capable devices, but it never tilts far enough to compromise legibility.

## 6. Do's and Don'ts

### Do:

- **Do** lead with a real application screenshot and specific product capability.
- **Do** use interactive product views and cinematic transitions to tell the story.
- **Do** keep body text under 68 characters per line.
- **Do** reserve #316BE8 and #7045E8 for important actions and product atmosphere.
- **Do** preserve a visible focus state and at least 44px interactive targets.
- **Do** show open-source and local-first proof close to download actions.

### Don't:

- **Don't** make the website look like the README was converted into stacked web sections.
- **Don't** resemble a generic AI startup template, a neon developer tool, or a dense SaaS dashboard.
- **Don't** use feature-list storytelling, gradient headlines, endless identical feature cards, decorative glass panels, vague claims, or aggressive sales language.
- **Don't** use gradient text or colored side-stripe borders.
- **Don't** animate layout properties or require motion to understand content.
- **Don't** replace real product imagery with decorative placeholder panels.
