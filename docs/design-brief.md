# Design brief: Predictex — a FIFA World Cup 2026 prediction league

> A copy-paste prompt for an AI frontend design tool ("Claude Design"). Written so the
> visual output maps cleanly back to the app's Phoenix LiveView + Tailwind + daisyUI stack.

---

## What I'm building
Predictex is a private prediction game for a small WhatsApp group of ~15 friends
following the 2026 FIFA World Cup. Players predict match scorelines (and, in the
knockouts, the first team and first player to score), earn points for accuracy, and
compete on a shared leaderboard. It's a social, casual, banter-driven app — not a
corporate betting product. The vibe is "group chat with a scoreboard."

Production lives at wc-predict.davewil.dev. The app name is "Predictex."

## Who uses it
- **Members** (the friends): register with a league invite code, view their personal
  prediction dashboard, and check the leaderboard. They make/edit their actual picks
  on FIFA.com and import them; Predictex shows them read-only.
- **One admin**: enters predictions on members' behalf from screenshots, syncs match
  results, and manages players.

## Design the following screens
1. **Leaderboard (`/`, public, the front door)** — ranked table of all players showing
   rank, points from fixtures, bonus points, and total. Rank #1–3 should feel
   celebratory. Prominent "Copy WhatsApp text" button (sharing standings to the group
   chat is the core social loop — design for that share moment). This is the page
   people open repeatedly during match days.
2. **My Predictions (`/predictions`, authenticated, read-only personal dashboard)** —
   the player's own picks organized by round (8 rounds: 3 group + 5 knockout), shown
   as fixture cards. Each card: two teams (with flag emoji), the player's predicted
   score, and — once results are in — a per-fixture points breakdown. Must clearly show:
     - a **2X booster marker** (one fixture per round can be doubled),
     - a **lock state** (predictions lock at kick-off; locked vs still-editable),
     - a **"no pick imported yet"** warning state,
     - the player's current **rank** up top.
   Include a link out to FIFA.com to edit picks. Tabs or segmented control per round.
3. **Register / Log in** — clean email + password forms; registration also takes a
   display name and a league invite code. Friendly, low-friction, on-brand.
4. **Admin console (`/admin`, planned)** — a utilitarian dashboard for one power user:
   enter predictions by-player or by-fixture, override/sync match results, enter a
   "cohort %" per fixture, and promote players. Prioritize speed and density over flair.

## Scoring vocabulary to surface visually (helps players understand their points)
Correct outcome +10 · correct home goals +5 · correct away goals +5 · correct goal
difference +5 · exact score bonus +5 · risky-pick bonus +10 (right call when <20% of
players agreed) · first team to score +5 and first scorer +10 (knockouts only) ·
all-correct round bonus +20. A good design makes a fixture's point breakdown legible
at a glance and makes the booster and risky-pick wins feel rewarding.

## Visual direction
- **Theme**: FIFA World Cup 2026. Lean into a pitch-green primary (current hero uses a
  green gradient ~#0a7d3c → #0f9d4f), with crisp white/neutral surfaces and a gold or
  warm accent for winners, boosters, and bonus moments. Football/stadium energy without
  cliché. Team identity via flag emoji.
- **Tone**: energetic, friendly, a little competitive. Big legible numbers (this is a
  scores app). Celebratory micro-moments for rank changes, exact scores, and booster hits.
- **Must work great on mobile** — most people check it on their phone in the group chat.
  Mobile-first, then scale up.
- **Dark mode**: support light and dark (the app has both); keep contrast strong for
  score tables.

## Hard technical constraint (important)
The app is **Phoenix LiveView**, styled with **Tailwind CSS + daisyUI** and **Heroicons**
— server-rendered HEEx templates, no React/SPA. Please design using **Tailwind utility
classes and daisyUI component patterns** (btn, card, table, badge, alert, tabs, navbar,
toast, etc.) so the output translates directly into HEEx. Avoid custom CSS, bespoke JS
animations, or anything that assumes a client-side framework. Compose screens as small,
reusable components (a FixtureCard, a LeaderboardRow, a RoundTabs control) rather than
monolithic pages.

## Deliverables
For each screen: a polished responsive layout (mobile + desktop), the component
breakdown, and the key states (loading/empty/locked/no-pick/results-in). Show the
FixtureCard and a LeaderboardRow in detail since they're reused everywhere.
