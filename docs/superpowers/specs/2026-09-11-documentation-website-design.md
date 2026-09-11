# English documentation website

The user approved a separate website PR following the English-only documentation PR, using the webtask developer-documentation experience as the reference.

Build an English MkDocs Material site for developers evaluating or integrating local-first-state. Its main job is to get a reader from the framework's behavior to the runnable example and the right client/backend guide. The homepage states TypeScript and Dart clients, a TypeScript backend SDK, and the shared Rust runtime. Source-alpha and platform limitations stay visible.

Navigation: Start (home, quick start, concepts), Clients (TypeScript, Dart), Backend (server SDK, Prisma, Nest), Project (compiler, testing, compatibility/recovery, implementation status, architecture, roadmap). Curate public entry points; historical design documents remain available through repository links instead of filling the main navigation with implementation plans.

Reuse existing repository Markdown during the build. Website-only content lives in `website/content`; a deterministic preparation script maps repository pages to site routes and fixes their links without changing fenced examples. Unpublished source references point back to GitHub. Generated staging and HTML are ignored.

Visual direction: white/slate surfaces, ink text, a restrained cobalt accent and a green local-state indicator. Use a native humanist sans-serif stack for body/display and a monospace stack for code. The homepage's signature is a simple local-write → queued mutation → authoritative settlement diagram, with a real quick-start command. Keep the standard accessible documentation navigation, search, code copy, theme toggle and mobile drawer. Avoid promotional statistics and unsupported platform badges.

Color tokens: paper `#ffffff`, canvas `#f5f7fb`, ink `#17243a`, muted `#58677d`, cobalt `#315ce8`, local green `#237d62`. Dark mode uses navy `#172033` and light ink `#e6edf7`. Desktop copy width stays readable; mobile stacks the introductory diagram and calls to action. Respect reduced motion and visible keyboard focus; do not load remote fonts or analytics.

Build validation runs on pull requests. GitHub Pages deployment is prepared as an explicit manual workflow from main after merge and Pages configuration. This task opens the website PR without merging it or publishing a live site.
