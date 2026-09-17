# MCP server ecosystem survey — ranked against Umbra/Fireplace

**Date:** 2026-09-10
**Sources:** primary only (own repos, own docs, GitHub REST API, the official MCP registry API, pub.dev API, PyPI API, local binaries). Every star count, `pushed_at` and release date below was pulled live on **2026-09-12** via the GitHub REST API. No listicle, aggregator or blog post is used as evidence anywhere in this document.
**Scope:** which MCP servers, if any, this project should mount. 46 candidates verified; 34 ranked.

---

## 0. TL;DR

- **The correct standing MCP count for this repo stays `1`** (Dart MCP, on probation). Nothing surveyed earns a permanent mount.
- **Postgres:** no. The reference server is archived; the popular replacement (`crystaldba/postgres-mcp`, 3.3k★) has shipped **no release since 2025-05-16** and its headline features need `hypopg` + `shared_preload_libraries` changes on a 4 GB production VPS. `docker exec … psql` keeps winning.
- **`chrome-devtools-mcp` (Google, 51.7k★, v1.9.0, 2026-09-08):** upgrade from "situational" to **"situational, and now worth an `npx` invocation for three specific jobs"** — performance traces, heap snapshots and **PWA install/launch**, none of which the native `browser` device exposes as curated tools. Still **not standing**: telemetry is on by default, and OMP *filters browser-automation MCP servers when the built-in browser prelude is enabled* (`omp://mcp-runtime-lifecycle.md` §2/§45), so a mount may be silently dropped.
- **NestJS / TypeORM / Jest:** nothing exists. Highest-starred NestJS MCP server is **38★**; the only Jest one is **0★**. `lsp` + `npm test` is not merely adequate, it is the only option.
- **Dart MCP:** measured locally — `dart mcp-server` (SDK 3.12.2) = **0.1.4**, pub-cache binary = **1.1.0**, pub latest = **1.1.1** (2026-08-07). **Agentic hot reload does NOT require the pub version** (`hot_reload` is in 0.1.4's feature list). The only feature 1.1.x adds is the `vm_service` meta tool. Bump 1.1.0 → 1.1.1 anyway (it is a free instruction-quality fix).
- **Remote/OAuth MCPs:** zero apply. Proven per-service in §6, not asserted.

---

## 1. Protocol state as of 2026-09 (this changes the fit maths)

Current spec revision is **`2026-07-28`** (`modelcontextprotocol.io/specification/versioning`: "The current protocol version is 2026-07-28"). Previous revision was `2025-11-25`. The `2026-07-28` key-changes page lists, as **major** changes:

| Change | Consequence for us |
|---|---|
| **MCP is now stateless.** `initialize` / `notifications/initialized` handshake removed; every request carries `io.modelcontextprotocol/protocolVersion` + `clientCapabilities` in `_meta` (SEP-2575) | Old and new servers now differ at the wire level. A server pinned to `2025-06-18` still works through backward-compat probing, but "it connects" no longer means "it is current". |
| **Protocol-level sessions and `Mcp-Session-Id` removed** from Streamable HTTP (SEP-2567) | Remote MCPs that leaned on session state must re-architect around server-minted handles. Expect churn in every hosted SaaS MCP through late 2026. |
| **`server/discover` added** — servers MUST implement it; on stdio it doubles as the backward-compat probe | A cheap maintenance signal: a server that has not implemented `server/discover` has not touched the spec since 2025. |
| **`resources/subscribe` + HTTP GET stream replaced by `subscriptions/listen`**; SSE resumability (`Last-Event-ID`) removed | The old "SSE transport" is doubly dead. A README still advertising `--transport=sse` (as `crystaldba/postgres-mcp` does) is a staleness tell. |
| **Multi Round-Trip Requests (MRTR)** replace server-initiated `roots/list`, `sampling/createMessage`, `elicitation/create` (SEP-2322); all results carry `resultType` | Servers do not initiate requests any more. Anything whose design depended on server→client sampling needs rework. |
| `ping`, `logging/setLevel`, `notifications/roots/list_changed` removed; tasks moved to the `io.modelcontextprotocol/tasks` extension | — |

**Transport guidance** (`modelcontextprotocol.io/docs/concepts/transports`) is unchanged in spirit and explicit: two standard bindings, **stdio** (newline-delimited JSON-RPC over a client-launched subprocess) and **Streamable HTTP** (POST per message, reply as JSON or a request-scoped SSE stream). Protocol semantics are identical on both. Custom transports over a byte stream *SHOULD* reuse stdio framing.

**Consequence for this stack:** stdio, local, no network. Streamable HTTP + OAuth buys multi-user credential brokerage — a thing a solo dev on one Windows box does not have. Every remote candidate in §6 is rejected partly on this.

### 1a. The official registry is not a quality signal in 2026-09

Measured against the registry API on 2026-09-12:

- `?search=postgres` returns **100 rows / 32 distinct server names**, of which **12 are mass-published `ai.getvda/*` "stack generator" remotes** published within 43 seconds of each other on 2026-09-03.
- `?search=flutter` returns **44 rows / 6 distinct names** — the API returns *version rows*, so one project (`io.github.ai-dashboad/flutter-skill`, 0.8.0 → 0.9.25) occupies ~26 of them.
- `?search=io.modelcontextprotocol` returns **0**. The seven official reference servers are **not published in the official registry at all**; `modelcontextprotocol/servers`' own README now points readers *to* the registry while the registry cannot find them.

So: the registry is a discovery index with no curation, no dedupe by project, and an incomplete official namespace. Registry presence was therefore used below only to confirm *published install surface + latest published version*, never as evidence of popularity or quality.

---

## 2. Provenance table (all figures pulled 2026-09-12 via GitHub REST API)

`★` = stargazers_count. `pushed` = `pushed_at`. Release = `releases/latest` tag @ publish date, or "none" when the project publishes no GitHub releases.

| # | Server / project | Owner | License | ★ | pushed | Latest release | Install surface | Egress | Tier |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `dart_mcp_server` (in `dart-lang/ai`) | dart-lang (Google) | BSD-3-Clause | 283 | 2026-09-11 | pub `1.1.1` @ 2026-08-07 (repo tag `skills-v1.0.1` @ 2026-09-04) | stdio via `cmd /c …\dart_mcp_server.bat` | Google `unified_analytics` **only if `DASH__TOOL` is set**; otherwise local | **A** (mounted, probation) |
| 2 | `chrome-devtools-mcp` | ChromeDevTools (Google) | Apache-2.0 | 51,689 | 2026-09-11 | `chrome-devtools-mcp-v1.9.0` @ 2026-09-08 | stdio `npx -y chrome-devtools-mcp@latest` | **Usage stats to Google, default ON**; perf tools send trace URLs to the CrUX API. Opt out: `--no-usage-statistics`, `--no-performance-crux`, or `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS` | **A** (ad-hoc only) |
| 3 | `modelcontextprotocol/servers` (7 reference servers) | modelcontextprotocol | Apache-2.0 / MIT mix (`NOASSERTION`) | 90,258 | 2026-09-03 | `2026.8.31` @ 2026-08-31 | stdio `npx`/`uvx` per server | filesystem/git/memory/time/sequentialthinking: none. `fetch`: arbitrary outbound HTTP | **C** |
| 4 | `microsoft/playwright-mcp` | Microsoft | Apache-2.0 | 37,025 | 2026-09-11 | `v0.0.80` @ 2026-09-01 | stdio `npx @playwright/mcp` | none (local browser) | **B** (removed here 2026-09-10) |
| 5 | `github/github-mcp-server` | GitHub | MIT | 32,882 | 2026-09-10 | `v1.12.1` @ 2026-09-08 | Docker `ghcr.io/github/github-mcp-server` **or** remote Streamable HTTP + OAuth | full repo/issue/PR content to GitHub API (already the case) + untrusted issue text into context | **C** (July verdict holds) |
| 6 | `oraios/serena` | oraios | MIT | 29,194 | 2026-09-08 | `v1.7.0` @ 2026-08-09 | stdio via `uvx`, Python | none | **B** |
| 7 | `upstash/context7` | Upstash | MIT | 61,900 | 2026-09-11 | `@upstash/context7-mcp@4.1.0` @ 2026-09-11 | stdio npm, `.mcpb` bundle, **or** hosted Streamable HTTP | **every library/topic query to Upstash's hosted service** | **C** |
| 8 | `ast-grep/ast-grep` | ast-grep | MIT | 15,862 | 2026-09-11 | `0.45.3` @ 2026-08-31 | CLI (no first-party MCP server) | none | **B** (already have `xd://ast_edit`) |
| 9 | `googleapis/mcp-toolbox` (ex-`genai-toolbox`) | googleapis | Apache-2.0 | 16,371 | 2026-09-11 | `v1.11.0` @ 2026-09-10 | **single Go binary incl. `windows/amd64`**, `--prebuilt=postgres` | none in self-hosted mode | **B** (best-in-class Postgres MCP; still loses to `psql` here) |
| 10 | `GLips/Figma-Context-MCP` | GLips | MIT | 15,843 | 2026-09-10 | `v0.13.2` @ 2026-06-18 | stdio npm + Figma API key | Figma file contents to Figma API | **C** |
| 11 | `zilliztech/claude-context` | zilliztech | MIT | 12,516 | **2026-07-14** | `v0.1.11` (tag only) | stdio npm + Zilliz/Milvus + embedding provider | **source code to an embedding provider** | **C** (hard no on a public E2EE repo: still leaks paths/symbols) |
| 12 | `wonderwhy-er/DesktopCommanderMCP` | wonderwhy-er | MIT | 9,550 | 2026-09-10 | `v0.2.50` @ 2026-09-09 | stdio npm | opt-out analytics | **C** (duplicates `bash`/`edit`/`read`) |
| 13 | `idosal/git-mcp` | idosal | Apache-2.0 | 8,381 | **2026-05-08** | none | hosted remote (`gitmcp.io`) | repo identity + queries to a third party | **C** |
| 14 | `AgentDeskAI/browser-tools-mcp` | AgentDeskAI | MIT | 7,318 | 2026-08-12 | `v2.0.2` @ 2026-08-12 | stdio npm + **Chrome extension + local middleware server** | local only | **C** (three moving parts; `chrome-devtools-mcp` dominates it) |
| 15 | `firecrawl/firecrawl-mcp-server` | firecrawl | MIT | 7,441 | 2026-09-12 | `v3.2.1` @ 2025-09-26 | stdio npm + API key | every URL + extracted content to Firecrawl | **C** |
| 16 | `sooperset/mcp-atlassian` | sooperset | MIT | 5,890 | 2026-09-05 | `v0.23.1` @ 2026-08-19 | stdio, `uvx` | Jira/Confluence API | **C** (no Atlassian here) |
| 17 | `executeautomation/mcp-playwright` | executeautomation | MIT | 5,644 | **2025-12-13** | none | stdio npm | none | **F** (9 months stale; superseded by #4) |
| 18 | `exa-labs/exa-mcp-server` | exa-labs | MIT | 4,994 | 2026-08-21 | none | stdio npm **or** hosted `ai.exa/exa` remote | all queries to Exa | **C** — and note OMP **filters Exa MCP servers by default**, extracting the key for the native Exa integration (`omp://mcp-runtime-lifecycle.md` §45) |
| 19 | `makenotion/notion-mcp-server` | makenotion (Notion) | MIT | 4,627 | 2026-07-25 | `v2.1.0` @ 2026-01-31 | stdio npm **or** `com.notion/mcp` remote+OAuth | workspace content to Notion | **C** |
| 20 | `cloudflare/mcp-server-cloudflare` | Cloudflare | Apache-2.0 | 4,184 | 2026-09-01 | `containers-mcp@0.2.19` @ 2026-08-11 | remote Streamable HTTP + OAuth | Cloudflare account data | **C** (no Cloudflare in this stack; OVH VPS + nginx) |
| 21 | `basicmachines-co/basic-memory` | basicmachines-co | **AGPL-3.0** | 3,932 | 2026-09-10 | `v0.23.2` @ 2026-08-25 | stdio, `uv`, local Markdown+SQLite | none | **C** (OMP has native memory; AGPL near a public repo needs care) |
| 22 | `grafana/mcp-grafana` | Grafana Labs | Apache-2.0 | 3,449 | 2026-09-11 | `v1.4.1` @ 2026-09-11 | stdio Go binary / Docker | Grafana instance | **C** (no Grafana; 4 GB VPS has no headroom) |
| 23 | `browserbase/mcp-server-browserbase` | Browserbase | Apache-2.0 | 3,405 | 2026-07-20 | `v3.0.0` @ 2026-03-31 | hosted cloud browser | **pages rendered in Browserbase's cloud** | **F** (`archived: true`) |
| 24 | `crystaldba/postgres-mcp` ("Postgres MCP Pro") | crystaldba | MIT | 3,293 | 2026-08-17 | **`v0.3.0` @ 2025-05-16** (PyPI `0.3.0`, same date) | stdio/SSE, `uvx`/`pipx`/Docker, Python | none | **C** — see §3 |
| 25 | `supabase/mcp` | Supabase | Apache-2.0 | 2,903 | 2026-09-11 | `mcp-server-supabase-v0.12.0` @ 2026-09-04 | stdio npm **or** `com.supabase/mcp` remote+OAuth | Supabase project data | **C** (no Supabase; self-hosted Postgres 16) |
| 26 | `tavily-ai/tavily-mcp` | tavily-ai | MIT | 2,378 | 2026-09-10 | none | stdio npm + API key | all queries to Tavily | **C** |
| 27 | `doobidoo/mcp-memory-service` | doobidoo | Apache-2.0 | 1,940 | 2026-09-11 | `v11.11.0` @ 2026-09-05 | stdio, Python, local vector store | none (local embeddings) | **C** |
| 28 | `docker/mcp-gateway` | Docker | MIT | 1,562 | 2026-08-26 | `v0.43.3` (tag only) | Docker Desktop / CLI plugin | per-server | **C** (aggregator; adds a layer over one server) |
| 29 | `isaacphi/mcp-language-server` | isaacphi | BSD-3-Clause | 1,591 | **2026-03-01** | `v0.1.1` @ 2025-05-16 | stdio Go binary | none | **F** (6 months stale; OMP has a native `lsp`) |
| 30 | `brave/brave-search-mcp-server` | Brave | MIT | 1,434 | 2026-09-10 | `v2.1.3` @ 2026-08-20 | stdio npm + API key | queries to Brave Search | **C** (official replacement for the archived reference server; `web_search` covers it) |
| 31 | `getsentry/sentry-mcp` | Sentry | `NOASSERTION` | 847 | 2026-09-12 | `0.39.0` @ 2026-08-27 | remote Streamable HTTP + OAuth, or stdio npm | issues/events to Sentry | **C** (July: self-hosted Sentry needs 16 GB; unchanged) |
| 32 | `ckreiling/mcp-server-docker` | ckreiling | **GPL-3.0** | 743 | 2026-08-07 | `v0.3.0` @ 2026-08-07 | stdio, Python, Docker socket | none | **C** (`docker` CLI over SSH already does this; socket access is a large blast radius) |
| 33 | `Arenukvern/mcp_flutter` | Arenukvern | MIT | 375 | 2026-09-08 | `v5.1.0` @ 2026-08-23 | stdio + OCI image | none | **C** (community duplicate of #1; 283★ first-party wins) |
| 34 | `BeehiveInnovations/pal-mcp-server` (was `zen-mcp-server`) | BeehiveInnovations | `NOASSERTION` | 11,744 | **2025-12-15** | `v9.8.2` @ 2025-12-15 | stdio, Python, needs its own model API keys | prompts to whichever model provider is configured | **F** (9 months stale, renamed; OMP `task`/`agent()` covers it natively) |

Also verified but not ranked as candidates (infrastructure / index / negative evidence): `modelcontextprotocol/modelcontextprotocol` (9,188★, `2026-07-28` @ 2026-07-28), `modelcontextprotocol/registry` (7,239★, `v1.8.1` @ 2026-08-06), `modelcontextprotocol/inspector` (10,864★, `2.6.0` @ 2026-09-09 — **the one thing here worth remembering** if we ever write an MCP server), `modelcontextprotocol/typescript-sdk` (13,373★), `python-sdk` (24,271★, `v2.2.0` @ 2026-09-07), `rust-sdk` (3,916★, `rmcp-v3.3.0` @ 2026-09-10), `PrefectHQ/fastmcp` (27,625★, `v4.0.3` @ 2026-09-05), `punkpeye/awesome-mcp-servers` (94,831★, index only), `modelcontextprotocol/servers-archived` (296★, **`archived: true`, last push 2025-05-28**), `vitest-community/mcp` (**8★** — the *official* Vitest MCP), `HenkDz/postgresql-mcp-server` (199★, AGPL-3.0, no releases), `alash3al/stash` (767★), `mrexodia/ida-pro-mcp` (11,975★).

---

## 3. Q1 — Is there a maintained Postgres MCP worth mounting vs `docker exec psql`?

**No.** Three candidates, in order of credibility:

**a) The reference PostgreSQL server — dead.** `modelcontextprotocol/servers`' README lists PostgreSQL under "### Archived", pointing at `servers-archived`, whose repo metadata is `"archived": true` with `pushed_at: 2025-05-28`. **No change since July.** The README still shows a `@modelcontextprotocol/server-postgres` config block in its Claude-Desktop example — that block documents an archived package; do not copy it.

**b) `crystaldba/postgres-mcp` ("Postgres MCP Pro"), 3,293★ — the popular answer, and a poor bet.** Evidence, all first-party:

- Latest release **`v0.3.0`, 2025-05-16**; tags stop at `v0.3.0`; PyPI `postgres-mcp` latest is **`0.3.0`, uploaded 2025-05-16**. That is **16 months without a release.**
- The three most recent commits are `2026-08-16 fix: Pin mcp[cli]<2.0 to prevent breaking import change #187`, `2026-01-22 Add streamable HTTP transport support`, `2026-01-20 refactor: …`. The 2026 activity is *maintenance to stop the SDK bump from breaking it*, not development.
- Its README still advertises `--transport=sse` and links to the SSE transport section of the docs — a transport the `2026-07-28` spec removed the last remnants of.
- The features that justify it over `psql` — index tuning and `get_top_queries` — **require `pg_stat_statements` and `hypopg`**. Its own README: `pg_stat_statements` must be listed in `shared_preload_libraries` (a Postgres **restart**), and "`hypopg` … may also require additional system-level installation … because it does not always ship with Postgres". On a **4 GB OVH VPS** running the only production database, that is a config change + restart + an extension build inside the Postgres container, to get index advice for a schema a solo dev already knows.
- Its "unrestricted" mode is full read/write DDL; its own README compares it to Cursor auto-run. On a production E2EE messenger DB, the only acceptable mode is `--access-mode=restricted`, which reduces it to… read-only SQL. Which is `psql`.

**c) `googleapis/mcp-toolbox` (16,371★, `v1.11.0` @ 2026-09-10) — the actually-maintained option, and still a no.** It is the strongest engineering here: single Go binary with a published **`windows/amd64`** download, `--prebuilt=postgres` for instant generic tools, plus a custom-tool YAML framework where you declare parameterised SQL. If this project ever needed a database MCP, this is the one. It is still rejected: its value proposition is *governed, parameterised tool surfaces for production agents* — a multi-developer/multi-agent-fleet problem. Here, one dev with SSH and `docker exec … psql` gets the same answers with zero schema tokens, zero new daemon, zero new credential path, and no second place where the production DSN lives.

**Verdict: `docker exec … psql` stands. July's "do not add" holds, now with the maintenance numbers behind it.**

---

## 4. Q2 — Is `chrome-devtools-mcp` standing-worthy for a Flutter web app, given the native `browser` device?

**Not standing. Yes, worth an `npx` call for three specific jobs.** This is a partial revision of the 2026-09-10 line "situational only; not standing" — the direction is unchanged, the *reason* sharpens.

Provenance first: **Google/ChromeDevTools org, Apache-2.0, 51,689★, `pushed_at` 2026-09-11, `chrome-devtools-mcp-v1.9.0` @ 2026-09-08**, created 2025-09-11 — it went 0.x → 1.x in twelve months and the npm registry entry is published in the official registry up to `v0.20.3`. This is a real, first-party, fast-moving project, not a toy.

**What it has that the native device does not.** The native `browser` prelude (`omp://tools/browser.md`) covers navigation, `observe()`, `ariaSnapshot()`, `screenshot()`, `extract()`, full interaction, waiting, `evaluate()`, and — crucially — raw Puppeteer `page` inside `tab.run`, plus relay/CDP/spawned modes. So *capability* is not the gap: anything reachable over CDP is reachable through `page`. The gap is **curated extraction**, and `chrome-devtools-mcp`'s 58-tool surface has three clusters we cannot cheaply reproduce:

1. **Performance** — `performance_start_trace` / `performance_stop_trace` / `performance_analyze_insight`, plus `lighthouse_audit`. These run the real DevTools frontend trace-insight engine. Reimplementing insight extraction on top of a raw `Tracing.start` dump is a project, not a snippet.
2. **Memory** — a 13-tool heap-snapshot cluster (`take_heapsnapshot`, `compare_heapsnapshots`, `get_heapsnapshot_retaining_paths`, `get_heapsnapshot_dominators`, `query_heapsnapshot_objects`, …). For a long-lived chat web app where a leak shows up as a tab that dies after an hour of message traffic, retaining-path analysis is exactly the tool, and writing it by hand is unreasonable.
3. **PWA** — `install_pwa`, `launch_pwa`, `get_os_app_state`, `uninstall_pwa`. Fireplace ships as an installable PWA and the deploy rule already calls for PWA prod verification. Nothing in the native device installs a PWA.

**What blunts it for Flutter web specifically.** The Flutter web build renders into a canvas (CanvasKit/skwasm). `take_snapshot`, `get_css_styles`, `fill_form`, the `aria/` selector machinery — i.e. most of the Input/Debugging clusters — see a canvas and almost no DOM. This is why sessions already drive CDP directly for Flutter. So the *tool-count* advantage is largely illusory here; the *three clusters above* are the whole case, and two of them (perf, memory) are diagnostic-only.

**Three reasons it must not be a standing mount:**

- **Schema cost with ~0 hit rate.** 58 tools of JSON schema loaded into every session, when the honest expected call rate is a handful per quarter. The same argument that removed `@playwright/mcp` applies with 4× the tool count. `--slim` reduces it but also drops the perf/heap clusters that are the entire reason to reach for it.
- **Egress, default-on.** From its own README: "Google collects usage statistics … Data collection is **enabled by default**", and "Performance tools may send trace URLs to the Google CrUX API." For this repo — a privacy-positioned E2EE messenger whose dev box holds signing material — a default-on telemetry channel is not something to leave mounted. Any invocation must carry `--no-usage-statistics --no-performance-crux` (or set `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`).
- **The harness may drop it anyway.** `omp://mcp-runtime-lifecycle.md`: discovery "filters disabled/project/Exa entries **and browser MCP servers when the built-in browser prelude is enabled**"; "browser automation MCP servers are filtered when `filterBrowser` is true". The docs do not publish the match list, so whether `chrome-devtools` matches is unverified from documentation alone — but a config entry that may be silently filtered is a bad place to put a standing dependency. **Ad-hoc `npx` for a single investigation sidesteps the question entirely.**

**Recommended shape (no repo change needed):** when a perf/leak/PWA question actually arises, run it once, out-of-band, with telemetry off:

```
npx -y chrome-devtools-mcp@latest --headless --no-usage-statistics --no-performance-crux
```

and record the finding in the session summary. Do not add it to `.omp/mcp.json`.

---

## 5. Q3 — Any MCP for NestJS / TypeORM / Jest that beats `lsp` + `npm test`?

**No. This is the clearest negative result in the survey.** Registry: `?search=nest` → 100 version-rows, **zero** NestJS developer-tooling servers (all noise from names containing "nest"); `?search=typescript` → 10 rows, **9 of them one project** (`jsc-typescript-ast-mcp`, 1.0.0→1.0.10); `?search=jest` → **0 results**; `?search=typeorm` → no server. GitHub repo search, sorted by stars:

| Query | Best result | ★ | pushed | Note |
|---|---|---|---|---|
| `nestjs mcp server` | `adrian-d-hidalgo/nestjs-mcp-server` | **38** | 2026-07-31 | a library for *building* MCP servers in Nest, not a dev tool |
| `typeorm mcp` | `Sayedfarabi/nest-typeorm-mcp-server` | **0** | 2026-01-22 | — |
| `jest mcp server` | `Swagatar-LLC/jest-mcp-server` | **0** | 2025-05-15 | 15 months stale |
| `vitest mcp server` | `vitest-community/mcp` (**official Vitest MCP**) | **8** | 2026-06-11 | wrong runner for this repo, and 8★ |
| `prisma mcp` | nothing credible | ≤6 | — | not our ORM anyway |

The nearest credible adjacent tools are **`oraios/serena`** (29,194★, MIT, `v1.7.0` @ 2026-08-09) and **`isaacphi/mcp-language-server`** (1,591★, last push **2026-03-01** — stale). Both exist to give an agent language-server semantics; OMP ships `lsp` natively (and `xd://ast_edit` for structural rewrites). Serena additionally bundles its own memory/onboarding layer, which duplicates harness features and adds a Python+`uv` dependency on a Windows box.

**Verdict: `lsp` + `npm test` + `xd://ast_edit` is not a compromise; there is nothing to trade up to.** Revisit only if a first-party NestJS or Jest MCP appears (watch `nestjs/*` and `jestjs/*` orgs, not the registry).

---

## 6. Q4 — Dart MCP: pub vs SDK-bundled, changelog since 1.1.0, and does agentic hot reload need the pub version?

All four sub-answers are measured on this machine, not inferred.

**Versions.**

| Path | Version | Evidence |
|---|---|---|
| `dart mcp-server` (SDK alias, Dart SDK **3.12.2** stable, Flutter **3.44.6**) | **0.1.4** | `dart mcp-server --version` → `0.1.4` |
| `…\Pub\Cache\bin\dart_mcp_server.bat` (what `.omp/mcp.json` mounts) | **1.1.0** | `dart_mcp_server.bat --version` → `1.1.0`; `dart pub global list` → `dart_mcp_server 1.1.0` |
| pub.dev latest | **1.1.1**, published **2026-08-07** | pub.dev API: versions `1.0.0` (2026-05-28), `1.0.1`, `1.0.2` (2026-06-22), `1.1.0` (2026-07-23), `1.1.1` (2026-08-07) |

So the September audit's "binary mismatch" is confirmed with numbers: **the SDK alias has *not* been rewired to the pub package on SDK 3.12.2**, despite the `1.0.0` changelog entry saying "`dart mcp-server` will continue to work as an alias for `dart run dart_mcp_server`". On this SDK it still runs the SDK-vendored `0.1.4`. Keeping the explicit pub-cache `.bat` path in `.omp/mcp.json` is therefore not redundant — it is the only way to get 1.x.

**Changelog since 1.1.0** (`dart-lang/ai/pkgs/dart_mcp_server/CHANGELOG.md`):

- **`1.1.1`** (2026-08-07) — one entry: "Improve server instructions and error messages to encourage agents to proactively connect to running applications and hot reload after changes." That is precisely the failure mode this project measured (0 agent calls in 100 sessions because nothing routed the agent to it). Free upgrade, directly on-target.
- **`1.1.2-dev`** (unreleased) — `create` tool passes the project root and rejects empty/whitespace `directory`; `AGENT_PLUGIN` tracked in analytics; license headers. Nothing needed here (`create_project` is already disabled in our mount).

**Does agentic hot reload require the pub version? No.** `dart mcp-server --help` on **0.1.4** lists `hot_reload` among its features, alongside `hot_restart`, `launch_app`, `get_runtime_errors`, `get_app_logs`, `widget_inspector`, `flutter_driver_command`, `dtd`. Diffing the two `--help` feature lists, the **only** difference is that 1.1.0 adds **`vm_service`** — the meta tool from the `1.1.0` changelog that connects to an app by VM-service URI and forwards arbitrary VM-service method calls. Everything else is identical by name.

So the real 1.x delta is: `vm_service` (useful precisely for the two-isolated-Chromes CDP recipe, because it removes the DTD dance for an already-running app), plus the `1.1.0` hardening work ("Harden various tools against compromised agents"; blocking analysis request instead of waiting for notifications that "may never come" — that last one is a genuine reliability fix for `analyze_files`).

**Egress:** analytics are gated on `DASH__TOOL` being set (`1.0.0` changelog: "Analytics will not be tracked if this is not set"), and `1.1.2-dev` adds `AGENT_PLUGIN` tracking to those events. Local-only in practice.

**Action:** `dart pub global activate dart_mcp_server 1.1.1` (or unpinned) — a one-line, no-risk bump that ships the exact instruction fix aimed at our zero-call problem. Mount path in `.omp/mcp.json` stays unchanged (`cmd /c …\dart_mcp_server.bat`), which is also the Windows pattern the MCP servers README prescribes for non-`uvx` stdio entries.

---

## 7. Q5 — Remote/OAuth MCPs: do any apply to a solo dev with no SaaS tracker?

**None. Proven per service, not asserted.** The 2026 ecosystem's centre of gravity really is hosted OAuth MCPs — the registry confirms first-party remotes for `app.linear/linear`, `com.notion/mcp`, `com.supabase/mcp` (`v0.12.0`, 2026-09-04), `io.github.github/github-mcp-server` (`v1.12.1`, 2026-09-08, `streamable-http`) and `ai.exa/exa`. Every one fails on a *stack* fact, not on taste:

| Remote MCP | Provenance | Why it does not apply |
|---|---|---|
| **GitHub** (`github/github-mcp-server`) | GitHub, MIT, 32,882★, `v1.12.1` @ 2026-09-08 | `gh` CLI is authenticated on this box (verified: `gh auth status` → logged in, scopes `gist, read:org, repo, workflow`, 5,000 req/h) and the harness already has `issue://` / `pr://` readers. The MCP adds schema tokens and pulls untrusted issue/PR prose into context as *tool output*. July's rejection stands verbatim. |
| **Linear** (`app.linear/linear`, remote-only, `streamable-http`) | first-party registry entry, no public repo (`linear/linear-mcp` → 404 via API) | **There is no tracker.** Issues live in GitHub Issues (`docs/agents/issue-tracker.md`; `docs/ISSUE-BOARD.md` was deleted 2026-09-17 as stale). Mounting a tracker MCP with no tracker is definitionally zero-value. |
| **Notion** (`makenotion/notion-mcp-server`, 4,627★, `v2.1.0` @ 2026-01-31; remote `com.notion/mcp`) | Notion, MIT | No Notion workspace. Docs are Markdown in the repo, which `read`/`grep` already index better than any API. |
| **Supabase** (`supabase/mcp`, 2,903★, `v0.12.0` @ 2026-09-04) | Supabase, Apache-2.0 | No Supabase. Postgres 16 runs in Docker on the VPS, reached by `docker exec`. There is no project ref to authorise. |
| **Sentry** (`getsentry/sentry-mcp`, 847★, `0.39.0` @ 2026-08-27) | Sentry, `NOASSERTION` | July: self-hosted Sentry needs 16 GB; the VPS has 4 GB. Unchanged. Sentry SaaS would mean shipping error payloads from an E2EE messenger to a third party — an explicit non-goal. The named gap (error tracking / GlitchTip) is a *hosting* decision, not an MCP decision. |
| **Cloudflare** (`cloudflare/mcp-server-cloudflare`, 4,184★) | Cloudflare, Apache-2.0 | No Cloudflare. nginx on one OVH VPS. |
| **Exa / Tavily / Firecrawl / Brave / Context7** | see §2 rows 7, 15, 18, 26, 30 | All are "send the query out, get text back". The harness has native `web_search` and `read <url>`; OMP *filters Exa MCP servers by default* and extracts the key for its native integration. Context7 additionally carries this project's own history: hosted, 1/100 sessions, prior key leak. |

**And one structural reason beyond per-service fit:** the `2026-07-28` spec deleted protocol sessions and the `initialize` handshake for Streamable HTTP. Remote MCPs are mid-migration right now. Adopting a hosted MCP this quarter means adopting someone else's migration, for a capability a CLI already covers.

**Answer: zero remote/OAuth MCPs apply. The correct standing MCP count remains 1 (Dart MCP, stdio, local).**

---

## 8. Ranking summary

**S — mount standing, now:** *(empty)*. No candidate clears the bar of "called often enough to justify permanent schema cost". This is the finding, not a gap in the survey.

**A — keep / reach for deliberately:**
- `dart_mcp_server` **1.1.1** — already mounted, on probation, bump the pinned version. The one MCP whose tools (`hot_reload`, `get_runtime_errors`, `widget_inspector`, `analyze_files`, `vm_service`) have no native equivalent in the harness.
- `chrome-devtools-mcp` **v1.9.0** — ad-hoc `npx` with telemetry flags off, for perf traces / heap retaining paths / PWA install verification only. Never in `.omp/mcp.json`.

**B — excellent, wrong problem here:** `microsoft/playwright-mcp` (native `browser` wins; removed 2026-09-10), `googleapis/mcp-toolbox` (best Postgres MCP; `psql` still wins), `oraios/serena` (native `lsp` wins), `ast-grep` CLI (`xd://ast_edit` wins), `modelcontextprotocol/inspector` (keep in mind *if* we ever author a server), `PrefectHQ/fastmcp` (ditto).

**C — popular, poor fit (with the reason stated plainly):** the 7 reference servers (`filesystem`/`git`/`memory`/`fetch`/`sequentialthinking`/`time`/`everything` — the repo's own README warns they are "reference implementations … not production-ready solutions", and each duplicates a native tool), `context7`, `exa`, `tavily`, `firecrawl`, `brave-search`, `github-mcp-server`, `supabase/mcp`, `notion-mcp-server`, Linear remote, `sentry-mcp`, `mcp-atlassian`, `mcp-grafana`, `cloudflare`, `basic-memory`, `mcp-memory-service`, `DesktopCommanderMCP`, `Figma-Context-MCP`, `zilliztech/claude-context`, `docker/mcp-gateway`, `ckreiling/mcp-server-docker`, `Arenukvern/mcp_flutter`, `idosal/git-mcp`, `AgentDeskAI/browser-tools-mcp`, `crystaldba/postgres-mcp`.

**F — dead, archived, or stale enough to be a liability:** `modelcontextprotocol/servers-archived` (`archived: true`, 2025-05-28 — includes **postgres, sqlite, puppeteer, github, brave-search, sentry, redis, slack, gitlab**), `browserbase/mcp-server-browserbase` (`archived: true`), `executeautomation/mcp-playwright` (2025-12-13), `isaacphi/mcp-language-server` (2026-03-01), `BeehiveInnovations/pal-mcp-server` (2025-12-15, renamed from `zen-mcp-server`).

### Windows / harness constraints that decided several rows

- stdio MCP entries on Windows need `cmd /c` wrapping for `npx`-based servers (the servers README says exactly this; `.omp/mcp.json` already does it for the Dart `.bat`). `uvx` entries do not.
- `hub start` cannot spawn `.bat` directly, so any candidate needing a Unix-only daemon or a background wrapper script is a poor fit. This rules out the "run a sidecar server plus a browser extension plus an MCP shim" shape (`AgentDeskAI/browser-tools-mcp`) and makes Docker-socket servers (`ckreiling/mcp-server-docker`) awkward as well as risky.
- Anything Python-based (`crystaldba/postgres-mcp`, `serena`, `basic-memory`, `mcp-memory-service`) adds a `uv`/`uvx` dependency to a Windows box whose toolchain is Node + Dart/Flutter + Docker-over-SSH.

---

## 9. What changed since the July audit

Only material changes are listed; everything not mentioned here is re-confirmed unchanged.

| Item | July / September position | State on 2026-09-12 | Material? |
|---|---|---|---|
| **Protocol revision** | (not assessed) | **`2026-07-28` is current**: stateless, no `initialize`, no sessions, `server/discover` mandatory, `subscriptions/listen`, MRTR, SSE resumability gone | **Yes** — new context for every remote-MCP decision, and a fresh staleness test for any candidate |
| **Postgres reference MCP** | archived 2025-05-28 | unchanged: `servers-archived` `archived: true`, `pushed_at` 2025-05-28 | No |
| **Best third-party Postgres MCP** | (not assessed in detail) | `crystaldba/postgres-mcp` 3,293★ but **no release since 2025-05-16**, 3 commits in 8 months, SSE-era README, needs `hypopg` + `shared_preload_libraries`. New entrant `googleapis/mcp-toolbox` 16,371★ `v1.11.0` @ 2026-09-10 with a Windows binary is the genuinely maintained option | **Yes**, but the verdict is the same: no Postgres MCP |
| **`chrome-devtools-mcp`** | "situational only; not standing" | **v1.9.0 @ 2026-09-08, 51,689★** (0.x → 1.x). Now has a 13-tool heap-snapshot cluster, `lighthouse_audit`, and **4 PWA tools** (`install_pwa`, `launch_pwa`, `get_os_app_state`, `uninstall_pwa`) that matter for our PWA prod check. Also: **usage telemetry default-ON** + CrUX trace-URL egress | **Yes** — sharpen to "ad-hoc `npx` with `--no-usage-statistics --no-performance-crux`, still never a standing mount" |
| **Dart MCP** | "keep on probation; resolve the 1.1.0-vs-0.1.4 binary mismatch" | Mismatch confirmed by measurement (`dart mcp-server` → **0.1.4**; pub-cache `.bat` → **1.1.0**; pub latest **1.1.1** @ 2026-08-07). `1.1.1` is a one-line release that *improves instructions to make agents hot-reload proactively* — aimed exactly at our zero-call problem. 1.x's only feature delta over 0.1.4 is `vm_service`; **hot reload does not require 1.x** | **Yes** — action: `dart pub global activate dart_mcp_server 1.1.1` |
| **GitHub MCP** | rejected (`gh` CLI covers it) | `v1.12.1` @ 2026-09-08, 32,882★, now also a first-party remote+OAuth. `gh` still authenticated with 5,000 req/h | No — rejection holds |
| **Sentry self-hosted** | needs 16 GB | `getsentry/sentry-mcp` `0.39.0` @ 2026-08-27 is healthy, but the blocker was always RAM, not the MCP | No |
| **`@playwright/mcp`** | removed 2026-09-10 (native `browser` device) | upstream healthy (`v0.0.80` @ 2026-09-01) and `executeautomation/mcp-playwright` now 9 months stale. OMP **filters browser-automation MCP servers when the browser prelude is enabled** | No — removal was right, and the harness reinforces it |
| **`context7`** | uninstalled (hosted, 1/100 sessions, past key leak) | very much alive (`4.1.0` @ 2026-09-11, 61,900★) and now ships an `.mcpb` bundle + hosted remote | No |
| **`gitleaks` / `osv-scanner` / `trivy`** | installed, situational | out of scope for an MCP survey; no MCP equivalent surfaced worth mentioning | No |
| **graphify** | removed 2026-09-10 (Dart edges 1.8% precision) | no MCP candidate in this survey occupies that niche; the closest (`zilliztech/claude-context`, 12,516★) ships source to an embedding provider and last pushed 2026-07-14 | No — do not backfill it |
| **Official registry as a source** | (not assessed) | **Actively unreliable**: version-rows not server-rows, mass-published spam, and the 7 official reference servers are absent (`?search=io.modelcontextprotocol` → 0) | **Yes** — use it for install surface only; verify at the repo |

---

## Sources

Every URL below was read during this survey.

**Spec and protocol**
- https://modelcontextprotocol.io/specification/latest
- https://modelcontextprotocol.io/specification/versioning
- https://modelcontextprotocol.io/specification/latest/changelog
- https://modelcontextprotocol.io/docs/concepts/transports

**Official registry API**
- https://registry.modelcontextprotocol.io/v0/servers?search=… for: `github`, `postgres`, `playwright`, `browser`, `filesystem`, `memory`, `sequential`, `fetch`, `docker`, `flutter`, `dart`, `typescript`, `nest`, `sqlite`, `sentry`, `linear`, `notion`, `context7`, `exa`, `brave`, `tavily`, `firecrawl`, `chrome-devtools`, `lsp`, `ast`, `git`, `jest`, `test`, plus targeted `crystaldba`, `dart-lang`, `modelcontextprotocol`, `io.modelcontextprotocol`, `serena`, `ast-grep`, `nestjs`, `typeorm`, `playwright-mcp`, `supabase`, `github-mcp-server`, `firecrawl`, `memory-bank`, `zen`

**Repos / READMEs / changelogs (raw)**
- https://raw.githubusercontent.com/modelcontextprotocol/servers/main/README.md
- https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/main/README.md
- https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/main/docs/tool-reference.md
- https://raw.githubusercontent.com/crystaldba/postgres-mcp/main/README.md
- https://raw.githubusercontent.com/googleapis/mcp-toolbox/main/README.md
- https://raw.githubusercontent.com/dart-lang/ai/main/pkgs/dart_mcp_server/CHANGELOG.md
- https://github.com/modelcontextprotocol/servers · https://github.com/modelcontextprotocol/servers-archived · https://github.com/punkpeye/awesome-mcp-servers (index only; every candidate re-verified at its own repo)

**GitHub REST API** (`https://api.github.com/repos/<owner>/<repo>` and `/releases/latest`, `/tags`, `/commits`, plus `gh search repos`) for: `modelcontextprotocol/{servers,servers-archived,modelcontextprotocol,registry,inspector,typescript-sdk,python-sdk,rust-sdk}`, `ChromeDevTools/chrome-devtools-mcp`, `microsoft/playwright-mcp`, `executeautomation/mcp-playwright`, `browserbase/mcp-server-browserbase`, `AgentDeskAI/browser-tools-mcp`, `dart-lang/ai`, `crystaldba/postgres-mcp`, `HenkDz/postgresql-mcp-server`, `supabase/mcp`, `github/github-mcp-server`, `getsentry/sentry-mcp`, `makenotion/notion-mcp-server`, `upstash/context7`, `exa-labs/exa-mcp-server`, `firecrawl/firecrawl-mcp-server`, `tavily-ai/tavily-mcp`, `brave/brave-search-mcp-server`, `oraios/serena`, `isaacphi/mcp-language-server`, `ast-grep/ast-grep`, `cyanheads/git-mcp-server`, `idosal/git-mcp`, `ckreiling/mcp-server-docker`, `docker/mcp-gateway`, `wonderwhy-er/DesktopCommanderMCP`, `BeehiveInnovations/pal-mcp-server`, `basicmachines-co/basic-memory`, `doobidoo/mcp-memory-service`, `GLips/Figma-Context-MCP`, `grafana/mcp-grafana`, `cloudflare/mcp-server-cloudflare`, `PrefectHQ/fastmcp`, `Arenukvern/mcp_flutter`, `sooperset/mcp-atlassian`, `zilliztech/claude-context`, `googleapis/mcp-toolbox`, `vitest-community/mcp`, `alash3al/stash`, `mrexodia/ida-pro-mcp`, `linear/linear-mcp` (404)

**Package registries**
- https://pub.dev/api/packages/dart_mcp_server · https://pub.dev/api/packages/dart_mcp
- https://pypi.org/pypi/postgres-mcp/json

**Local, this machine (2026-09-12)**
- `dart --version` → Dart SDK 3.12.2 (stable) · `flutter --version` → Flutter 3.44.6
- `dart mcp-server --version` → `0.1.4`; `dart mcp-server --help` (feature list)
- `…\Pub\Cache\bin\dart_mcp_server.bat --version` → `1.1.0`; `--help` (feature list; `vm_service` is the only delta)
- `dart pub global list` → `dart_mcp_server 1.1.0`
- `gh auth status` / `gh api rate_limit`
- `.omp/mcp.json`; `docs/agents/workflow-2.0.md` §5a; `omp://tools/browser.md`; `omp://mcp-runtime-lifecycle.md`
