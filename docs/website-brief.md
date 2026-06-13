# TileCam Website — Design & Build Brief

> **Purpose of this document.** A complete, self-contained brief to hand to **Claude (claude.ai)** — run with **Opus** — to design a small design system and build a set of simple, static, AI-maintainable web pages for the TileCam app. It carries over TileCam's existing app design language and supplies the real page content (especially the legally-load-bearing privacy & support copy) so the agent **builds**, it does not invent facts about the product.

---

## 1. What we're building

A tiny marketing + legal website for **TileCam**, an Apple-platform camera-viewing app. Four pages, static HTML/CSS (a little JS only where it earns its place), dark glassomorphic theme matching the app. It must be trivial for an AI agent to keep updated over time — so favour **plain, readable, hand-editable HTML/CSS over a framework or build step**.

Two of these pages are **hard requirements for App Store submission** (Apple requires a reachable privacy-policy URL and a support URL), so they must be real, accurate, and live before the app can ship.

**Pages**
1. **Home / landing** — what TileCam is, who it's for, key features, platforms, App Store CTA.
2. **Privacy Policy** *(required URL)* — drafted in §6 below. Use it close to verbatim.
3. **Support** *(required URL)* — drafted in §7 below (overview, FAQ/troubleshooting, contact).
4. **Terms of Use** — drafted in §8 (short; covers the in-app purchase).

---

## 2. The product (so copy is accurate — do not embellish beyond this)

**TileCam** is a camera-management and live-streaming app for Apple platforms. It shows live camera feeds from a user's **own** [go2rtc](https://github.com/AlexxIT/go2rtc) / WebRTC server — the user configures their server URL; **TileCam runs no servers and no cloud of its own**. Streams flow **directly** between the user's device and their own camera server.

- **Platforms:** iPhone, iPad, Mac (Designed for iPad / Catalyst) — iOS 17+. Apple **Watch** companion — watchOS 10+. **Dark mode only.**
- **Core features:**
  - Multi-camera live streaming (WebRTC, low latency) in a clean tile grid.
  - Two-way / live **audio** for cameras that support it, with per-stream mute.
  - **Motion visualization** overlays: "breathing" magnification (Eulerian), motion flow (directional), and an intensity heatmap.
  - **Picture-in-Picture** — keep a camera floating while you use other apps.
  - **Apple Watch** companion to glance at cameras on your wrist (a paid one-time unlock — see Terms).
  - Background audio (opt-in) and keep-screen-awake options.
- **Audience (two overlapping):** *home/family* users (baby/pet/home monitoring) who want calm, glanceable reassurance; and *prosumer hobbyists* running their own go2rtc setups who want power **and** polish. The feel is "checking a luxury dashboard," not "operating a security system."
- **Business model:** the iPhone/iPad app is free; the Apple Watch companion is a **one-time non-consumable in-app purchase** (Family Sharing enabled).

**Naming:** product/app is **TileCam**. (Repo is internally "GlassView" — do **not** use that name on the site.) Bundle id `works.rainn.tilecam`.

> **Placeholders the human must fill before publishing:** `[Company legal name]`, `[support email]`, `[App Store link]`, `[effective date]`, `[website domain]`. Leave these as visible tokens in the build.

---

## 3. Brand & voice

From the app's design context (`.impeccable.md`):

- **Personality:** Playful, modern, snappy — "like Apple's own apps." Delightful micro-interactions, an interface that feels *alive* without being distracting. Every visit should spark a small "this is nice."
- **Voice in copy:** confident, warm, concise, a little delightful. Short sentences. No enterprise-security jargon, no fear-selling. For families: calm and reassuring. For hobbyists: precise and respectful of their competence.
- **Anti-references:** cluttered dashboards, flat gray enterprise UI, skeuomorphism, heavy drop shadows, stock-photo "security" cliché.

---

## 4. Design system (port the app's `.impeccable.md` to the web)

Build a small, documented design system (a single `styles.css` with CSS custom properties + a one-page style reference is ideal). Translate these app tokens faithfully:

### Foundations
- **Theme:** dark-only. **Pure black** background (`#000`). No light mode.
- **Depth via glass, not shadows.** Frosted-glass surfaces (`backdrop-filter: blur(...)` + low-opacity white fill + thin luminous border). Avoid drop shadows entirely except the subtle colored glow on status dots.
- **Opacity is the hierarchy system. Never use gray — always white at an opacity on black:**
  - `rgba(255,255,255,1.0)` = primary text
  - `0.6` = secondary text
  - `0.35` = tertiary / captions
  - `0.15` = decorative / dividers / glass fills
- **Typography:** system San Francisco stack — `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif`. Hierarchy comes from **weight + opacity**, not size alone. Generous line-height for body.
- **Color is semantic only** (status), never decorative:
  - Connected/active/success: `green` (`#34C759`-ish) with a soft `rgba(52,199,89,0.4)` glow
  - Warning: `orange` ~`0.7` opacity
  - Error: `red` ~`0.8`
  - Connecting/checking: `yellow`

### Token scales (use as CSS variables)
- **Spacing:** `2 · 4 · 6 · 8 · 12 · 16 · 24 · 32` (px)
- **Corner radius:** `4 (small) · 12 (buttons) · 14 (segments) · 20–24 (panels/cards)`
- **Motion durations:** `0.15s (micro) · 0.2s (fast) · 0.25s (standard) · 0.3–0.35s (entrance) · 0.4s (major)`. Use spring-like easing for interactive elements (`cubic-bezier(0.34, 1.4, 0.64, 1)` approximates the app's interactive spring); smooth ease for transitions. **Stagger** entrance animations ~40ms per item. Respect `prefers-reduced-motion`.

### Glass surface recipes (web equivalents of the app's)
- **Card / panel:** `background: rgba(255,255,255,0.06)` + `border: 1px solid rgba(255,255,255,0.12)` + `backdrop-filter: blur(20px)` + radius `20–24`.
- **Button / token (primary):** `background: rgba(255,255,255,0.15)` + `border: 1px solid rgba(255,255,255,0.2)` + radius `12`. Hover: subtle scale (`1.02`) and a touch more opacity. Active: scale `0.98`. (Springy, physical.)
- **Status dot:** small filled circle in the semantic color with a matching soft glow.

### Layout & quality bars
- Fully **responsive** (mobile-first; looks great on a phone since that's the product's home turf).
- **Accessible:** semantic HTML, real headings, sufficient contrast (white-on-black is fine; watch the `0.35` tier for small text — bump it for body legibility), focus-visible states, alt text, keyboard-navigable. Target WCAG AA.
- **Performance:** no heavy frameworks. System fonts (no web-font downloads). Inline critical CSS or a single small stylesheet. Pages should be a few KB.
- **Disappearing-UI principle:** let content breathe; lots of black space; chrome is minimal. The (eventual) product screenshots are the hero, not the buttons.

---

## 5. Page-by-page spec

### 5.1 Home / landing
- **Hero:** TileCam wordmark/logo (a `TileCamLogo` asset exists in the app — request it from the human, or set type in SF for now), a one-line value prop ("Your cameras, beautifully. Live on every Apple device."), and an **App Store download** CTA (`[App Store link]`). Dark, spacious, one tasteful glass element.
- **Feature sections** (3–5, each a glass card with an icon + short copy): Multi-camera live view · Motion visualization (breathing/flow/heatmap) · Picture-in-Picture · Apple Watch companion · Private by design (streams to *your* server, nothing through us).
- **Platforms strip:** iPhone · iPad · Mac · Apple Watch. iOS 17+ / watchOS 10+.
- **"Private by design" highlight:** one short section restating the privacy posture (no accounts, no cloud, no tracking) — this is a genuine selling point for this audience. Link to the Privacy Policy.
- **Footer:** links to Privacy, Support, Terms; `© [year] [Company legal name]`.
- **Note for the agent:** real device screenshots don't exist yet — leave tasteful glass placeholders sized for later drop-in, and say so in a comment.

### 5.2 Privacy Policy — use §6 content. Clean long-form reading layout (max-width ~680px, generous line-height, body text at full or `0.85`+ white, headings full white/semibold). Show `Last updated: [effective date]`.

### 5.3 Support — use §7 content. Overview + an accessible FAQ/troubleshooting accordion (or just headed sections — keep JS minimal) + a contact block (`[support email]`).

### 5.4 Terms of Use — use §8 content. Same reading layout as Privacy.

---

## 6. Privacy Policy content (accurate to the app — use ~verbatim)

> **Effective date:** [effective date]
> **App:** TileCam · **Provider:** [Company legal name] ("we," "us")

**The short version.** TileCam is built to keep your data on your devices. We do not run servers for your video, we do not collect analytics, we do not track you, and we have no accounts. Your camera streams go directly between your Apple device and the camera server **you** configure — never through us.

**What we collect: nothing.** TileCam does not collect, store, or transmit any personal information to us or to any third party. There is no sign-up, no account, and no analytics or advertising SDKs in the app. We cannot see your cameras, your streams, or your server.

**Your video and audio.** TileCam connects to the go2rtc / WebRTC camera server that you set up and point it at. All live video and audio flows **directly** between your device and that server (on your local network or wherever you host it). It is never routed to, recorded by, or stored by us.

**Information stored only on your device.** Your settings — your server address and app preferences — are stored locally on your device using Apple's standard on-device storage. If you use the Apple Watch companion, those settings and the live frames are sent between your iPhone and your **own paired Apple Watch** using Apple's WatchConnectivity; they do not pass through us.

**Microphone.** If you use live audio with a camera that supports it, TileCam uses the microphone only for that real-time WebRTC audio session. Audio is not recorded or saved by the app, and is not sent to us.

**Local network.** TileCam asks for local-network access so it can reach camera servers running on your home/office network. This is used solely to connect to the servers you configure.

**Purchases.** The Apple Watch unlock is a one-time in-app purchase processed entirely by Apple. We never receive your payment-card details. Apple handles the transaction under Apple's privacy policy.

**Tracking.** We do not track you across apps or websites, and the app contains no tracking technologies. (Our App Store privacy disclosures and bundled privacy manifest reflect this.)

**Children.** TileCam does not collect data from anyone, including children.

**Changes.** If this policy changes, we'll update this page and the effective date above.

**Contact.** Questions? Email [support email].

---

## 7. Support content

**TileCam Support**

TileCam shows live camera feeds from your own go2rtc / WebRTC server on your iPhone, iPad, Mac, and Apple Watch.

**Getting started**
1. Set up a [go2rtc](https://github.com/AlexxIT/go2rtc) server and add your cameras to it.
2. In TileCam, enter your server's address (e.g. `http://192.168.1.100:1984`) and tap **Connect**.
3. Pick the cameras you want to see — they appear as live tiles.

**FAQ / troubleshooting**

- **No cameras / tiles appear after connecting.** Double-check the server address and that the server is reachable from your device's network. TileCam now automatically retries the connection on launch and when you return to the app; you can also pull the manual **Retry** action on the "Cannot reach server" screen.
- **A camera has no sound.** Audio is per-stream and can be muted. Tap the audio/waveform control on that camera's tile to unmute it. (If a camera truly has no audio source, that's a setting on the camera/go2rtc side, not TileCam.)
- **Streaming keeps running / battery drain when I leave the app.** When you background TileCam while viewing, the camera keeps floating in Picture-in-Picture by design. To stop it completely, **close the PiP window** — the app then suspends fully.
- **Apple Watch app asks me to unlock.** The Watch companion is a one-time purchase. Buy or **restore** it from the iPhone app's Watch settings; the unlock then syncs to your Watch.
- **Local-network permission.** TileCam needs local-network access to reach cameras on your home network. If you declined it, enable it in iOS Settings → TileCam.

**Contact**
Email **[support email]** and we'll help. Include your device model and iOS/watchOS version.

---

## 8. Terms of Use content (short)

> **Effective date:** [effective date]

- TileCam is provided by [Company legal name]. By using it you agree to these terms and to Apple's standard [EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).
- **What TileCam does:** it displays camera streams from servers **you** provide and control. You are responsible for your own camera hardware, servers, and for complying with all laws regarding recording and monitoring in your jurisdiction.
- **In-app purchase:** the Apple Watch unlock is a one-time non-consumable purchase, eligible for Family Sharing, processed by Apple. Refunds are handled by Apple.
- **No warranty:** TileCam is provided "as is," without warranty. We are not liable for missed events, downtime, or anything you rely on the app to monitor.
- **Changes:** we may update these terms; continued use means acceptance.
- **Contact:** [support email].

---

## 9. How to run this with Claude

1. Open **claude.ai**, select **Opus**.
2. Paste this brief. Ask it to **first establish the design system** (the `styles.css` + a small style-reference page) from §4, then build the four pages from §5–§8.
3. Deliverables: a folder of static files — `index.html`, `privacy.html`, `support.html`, `terms.html`, `styles.css`, plus any small shared header/footer partial. No build step; openable directly in a browser.
4. Have it keep all human-fill values as visible `[bracketed]` tokens (§2) so they're easy to find and replace before publishing.
5. **Hosting:** any static host works (e.g. GitHub Pages, Netlify, Cloudflare Pages). The **privacy** and **support** URLs are what go into App Store Connect, so settle the `[website domain]` and final paths before submitting the app.

**Acceptance bar:** dark glassomorphism faithful to the app; privacy/support/terms copy from §6–§8 present and accurate; fully responsive and accessible (WCAG AA); no frameworks/build step; loads fast; placeholders clearly marked.
