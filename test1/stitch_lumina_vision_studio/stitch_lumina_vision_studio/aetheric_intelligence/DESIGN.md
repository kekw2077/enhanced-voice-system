---
name: Aetheric Intelligence
colors:
  surface: '#f7f9fb'
  surface-dim: '#d8dadc'
  surface-bright: '#f7f9fb'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f2f4f6'
  surface-container: '#eceef0'
  surface-container-high: '#e6e8ea'
  surface-container-highest: '#e0e3e5'
  on-surface: '#191c1e'
  on-surface-variant: '#464554'
  inverse-surface: '#2d3133'
  inverse-on-surface: '#eff1f3'
  outline: '#767586'
  outline-variant: '#c7c4d7'
  surface-tint: '#494bd6'
  primary: '#4648d4'
  on-primary: '#ffffff'
  primary-container: '#6063ee'
  on-primary-container: '#fffbff'
  inverse-primary: '#c0c1ff'
  secondary: '#b4136d'
  on-secondary: '#ffffff'
  secondary-container: '#fd56a7'
  on-secondary-container: '#600037'
  tertiary: '#006577'
  on-tertiary: '#ffffff'
  tertiary-container: '#008096'
  on-tertiary-container: '#f9fdff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#e1e0ff'
  primary-fixed-dim: '#c0c1ff'
  on-primary-fixed: '#07006c'
  on-primary-fixed-variant: '#2f2ebe'
  secondary-fixed: '#ffd9e4'
  secondary-fixed-dim: '#ffb0cd'
  on-secondary-fixed: '#3e0022'
  on-secondary-fixed-variant: '#8c0053'
  tertiary-fixed: '#acedff'
  tertiary-fixed-dim: '#4cd7f6'
  on-tertiary-fixed: '#001f26'
  on-tertiary-fixed-variant: '#004e5c'
  background: '#f7f9fb'
  on-background: '#191c1e'
  surface-variant: '#e0e3e5'
typography:
  display-lg:
    fontFamily: Inter
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.01em
  title-md:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '500'
    lineHeight: 28px
    letterSpacing: 0em
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
    letterSpacing: 0em
  body-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
    letterSpacing: 0em
  label-caps:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.08em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 8px
  xs: 4px
  sm: 12px
  md: 24px
  lg: 40px
  xl: 64px
  container-max: 1440px
  gutter: 24px
---

## Brand & Style

The design system is built on a foundation of **Ethereal Modernism**. It merges the hyper-clean, airy functionalism of high-end productivity tools with the tactile, premium feel of frosted glass and soft light. The brand personality is intelligent, visionary, and calm, designed to make the complex process of AI image generation feel effortless and magical.

The aesthetic utilizes **Glassmorphism** to create a sense of depth and focus. Surfaces are treated as semi-transparent panes that filter the background, emphasizing a multi-layered interface that feels "live" and responsive. High-contrast gradients are reserved strictly for AI-driven moments, signaling a transition from manual input to machine creativity.

## Colors

The palette is anchored by a neutral, high-key background to maximize the "airy" feel. 

- **Primary (Indigo):** Used for primary actions, active states, and brand-critical iconography.
- **AI Gradient:** A signature blend of Deep Violet to Cyan. This is the "Generative Signal"—it should only appear on buttons, progress bars, or borders specifically tied to AI processing.
- **Surface Strategy:** Backgrounds are a very light grey (`#F8FAFC`). Surfaces use a semi-transparent white with a high backdrop-blur (20px+) to simulate heavy frosted glass. 
- **Status Colors:** Use soft, desaturated versions of green (Success), amber (Warning), and rose (Error) to maintain the calm aesthetic.

## Typography

This design system uses **Inter** exclusively to achieve a systematic, clean, and highly legible look reminiscent of modern operating systems. 

- **Hierarchy:** Use weight to differentiate rather than extreme size shifts. 
- **Headings:** Display and Headline levels should use slightly tighter letter spacing (`-0.01em` to `-0.02em`) to feel more cohesive and premium.
- **Labels:** Use `label-caps` for secondary metadata or small section headers to introduce a rhythmic contrast to the sentence-case body text.
- **Readability:** Maintain a line height of at least 1.5x for body text to preserve the "airy" feel.

## Layout & Spacing

The layout follows a **Fluid Grid** model with generous white space to prevent the interface from feeling cluttered during the creative process.

- **Desktop:** 12-column grid, 24px gutters, and 40px side margins. 
- **Tablet:** 8-column grid, 20px gutters, 24px side margins.
- **Mobile:** 4-column grid, 16px gutters, 16px side margins.
- **Rhythm:** Spacing should follow an 8px scale. Use `lg` (40px) or `xl` (64px) spacing between major sections to emphasize the "minimalist" narrative. Content cards should be center-aligned in a max-width container to maintain focus.

## Elevation & Depth

Depth is conveyed through **Physicality and Light**, not heavy shadows.

- **Glass Layers:** Surfaces use `backdrop-filter: blur(24px)` combined with a 1px solid white border at 40% opacity. This creates a "rim light" effect that separates the surface from the background.
- **Shadows:** Use only one type of shadow: an extremely diffused, low-opacity "Ambient Bloom." 
  - *Bloom:* `0px 10px 40px rgba(0, 0, 0, 0.04)`.
- **Active State:** When an element is pressed, it should physically scale down slightly (e.g., `scale(0.98)`) and increase its blur intensity, rather than getting darker.

## Shapes

The shape language is dominated by "Squircle"-like softness. 

- **Standard Elements:** Buttons and input fields use `rounded-lg` (1rem / 16px).
- **Cards & Containers:** Main layout containers and image result cards use `rounded-xl` (1.5rem / 24px).
- **Pills:** Search bars and status chips should use a fully rounded (pill) radius for a more approachable, modern feel.
- **Borders:** Borders on glass surfaces should always be thin (1px) to maintain a refined, high-tech look.

## Components

### Buttons & Inputs
- **Primary Action:** Large, pill-shaped buttons. AI-specific actions (e.g., "Generate") use the Indigo-to-Cyan gradient with white text.
- **Ghost Buttons:** For secondary actions, use a 1px border with a subtle hover fill at 5% opacity.
- **Search/Prompt Input:** Extra-large rounded fields (min-height: 64px) with a semi-transparent white background. The inner text should be `body-lg`.

### Cards
- **Image Cards:** These should have a subtle inner glow on hover. Metadata (dimensions, prompt) should appear on a glass overlay that slides up from the bottom.
- **Control Cards:** Sidebars for settings (aspect ratio, style) should be persistent glass panels with clear, icon-led lists.

### Floating Action Buttons (FAB)
- Use FABs for "New Project" or "Help" actions. These should sit at the bottom right, using a more aggressive background blur and a primary color icon.

### Feedback & Transitions
- **Hover States:** Instead of a color change, use a 1.02x scale up and a slight increase in the `backdrop-filter` blur.
- **Loading:** Use a shimmering "Aurora" animation across the AI gradient to indicate the model is thinking.