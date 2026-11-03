# Tunory — Product Roadmap

**Status:** Proposed product plan, not a claim that every feature has shipped  
**Baseline:** 2026-11-03 · `raelldottin/tunory` · `main` at `d7589ebb5f1ef4e7669227f966d36307e33bcfab`  
**Primary platform:** macOS; iOS is a later, separately accepted product surface  
**First distribution route selected:** macOS internal TestFlight, not public App Store distribution  
**Decision authority:** product owner. Each engineering slice follows `AGENTS.md`, applicable CI and agent-review gates, and explicit acceptance evidence.

## 1. Vision and product promise

**Tunory is a personal music intelligence app: tell it what you want to hear, in text or by voice; it helps you build, organize, and repair playlists using your own music and eligible connected services.**

Tunory has four complementary jobs:

1. **Bring music in.** Import albums and songs from local audio files into the macOS Music library, with safe format conversion and no Apple Music streaming subscription requirement.
2. **Keep collections clean.** Detect and safely resolve duplicate recordings or duplicate playlist entries, without silently changing the user's original files or library.
3. **Create for a moment.** Turn a mood, interest, activity, or natural-language prompt into a reviewable playlist proposal and then a verified playlist on a supported destination.
4. **Let the user choose their source.** Work with local files independently; optionally connect Apple Music catalog or Spotify where authentication, API access, terms, and subscription conditions permit.

The experience is **intent → transparent plan → review → authorized change → independent verification**. A useful result is a playlist that actually contains the intended recordings and remains correct after retry or interruption—not merely a successful API response.

### Signature user journeys

- **Four FLAC albums:** Select four folders; recognize existing Music.app recordings across codecs; convert only needed tracks to AAC 256 kbps or optional ALAC; add only missing recordings; verify album metadata, order, and zero unintended duplicates.
- **Mood playlist:** “I need an energetic 45-minute playlist for my evening walk.” Tunory interprets the user's own words, presents track choices and rationale, and builds a playlist from an eligible selected source.
- **Playlist cleanup:** Choose an existing playlist; see exact and probable duplicate entries with keep/remove previews; authorize selected removals; verify the revised sequence.
- **Library-only mode:** Use local albums and playlists when Apple Music streaming access is absent, expired, or never configured.
- **Multi-provider preference:** Choose local, Apple Music, or Spotify as the target; see the available capabilities and account restrictions before requesting an action. A common *intent* must not be misrepresented as a single interoperable streaming playlist.

### Primary audiences

- Music collectors with MP3, AAC, FLAC, ALAC, WAV, AIFF and other legitimately owned local files.
- Playlist enthusiasts who want better organization and fewer duplicates.
- Apple Music users who want verified, precise playlist construction.
- People who describe their listening intent naturally and prefer conversational/voice interaction.
- Spotify users **only within the access and policy envelope actually granted to Tunory**.

## 2. Non-negotiable product principles

1. **Local-first, subscription-optional.** Core local-file import, conversion, indexing and safe local playlist hygiene must not require Apple Music, Spotify, LLM connectivity, or a paid streaming subscription.
2. **No unapproved library writes.** All externally visible mutations require explicit intent and a preview. Never silently overwrite originals, edit Music's database, remove tracks, or rebuild a diverged playlist.
3. **Idempotency and evidence.** Reconcile against freshly read state before uncertain retries. The last write response is not proof of the final result; show post-write verification and honest unknown/blocked states.
4. **Recording identity is provider-scoped.** An Apple Music catalog ID, a Music.app persistent ID, a Spotify track URI, and a local file fingerprint are different identifiers; none is an automatic substitute for another.
5. **Ambiguity is a product state.** Same metadata does not prove the same recording; remasters, live performances, editions and alternate mixes demand conservative review.
6. **The model proposes; deterministic code decides.** LLMs may parse the user's intent and suggest a plan, but do not own authorization, duplicate judgments, credential use, writes, or transaction verification.
7. **User data is private by default.** Explicit microphone permission, consent before sending prompts externally, Keychain-based secrets, minimum retention, clear deletion controls, and no background mic recording.
8. **Provider compliance before exposure.** Honor Apple, Spotify and third-party terms; use platform-approved APIs; do not circumvent DRM or download inaccessible streaming content.
9. **A feature is not released because it compiles.** Tests, signed-app entitlements, live permission dialogs, authorized disposable writes, UI accessibility and distribution proof are separate gates.

## 3. Repository baseline and evidence classification

The following is a dated repository snapshot, **not a blanket statement about deployed functionality**.

| Capability or asset | Evidence as of 2026-11-03 | Status for roadmap |
| --- | --- | --- |
| Apple Music catalog playlist transactions, exact ordering and recovery | Implemented on `main`; earlier 17-track live API proof; see `docs/apple-music-integration-retrospective.md` and `docs/phase9-beta-productization.md` | Existing capability; full new-build GUI acceptance remains independently gated |
| Product app icon | Merged PR #11 and `docs/app-icon.md`; icon resources for macOS and iOS | Done in repository; installed/device and App Store rendering still separately verifiable |
| Local file conversion, native AAC/ALAC, Music.app import adapter | PRs #3, #5 and #4, all still open and stacked | Implemented on branches, not integrated into `main` |
| Four-folder FLAC handling, pre-conversion Music-library survey, conservative cross-format duplicate handling, signed sandbox write access | PR #12, on top of the stack | Automated and signed-app evidence on PR branch; not production release |
| Four-album acceptance scenario | PR #12: 40 FLAC files, 13 already represented, 27 missing, 0 unintended duplicates; re-run adds 0 | **Mocked Music library**, not authorized live Music.app proof |
| Independent validation of Phase 11 work | PR #12 reports 275/275 TunoryCore, 72/72 app-hosted tests, Debug and Release builds; GUI XCTest encountered an environment blocker | Strong automated proof; GUI/live TCC and distribution proof outstanding |
| Core CI, exact-commit review, protected branch policy, `dev` | Merged PR #6; `docs/gitops-next-actions.md` and `docs/native-review-policy.md` | Repository workflow baseline; validate each proposed PR's own checks |
| macOS internal TestFlight artifact | `docs/releases/macos-internal-testflight-2026-10-21.md`: successful local archive and internal-only export from an **older** source revision | Prepared artifact only; no upload, processing, group assignment or tester installation proven |
| AI playlist generation, voice input, Spotify integration, playlist duplicate removal | No verified implementation in reviewed baseline | Proposed workstreams; do not describe as shipped |

**Existing open, stacked engineering chain (preserve until separately reviewed):**

`main ← #1 (guidance) ← #2 (UI robustness) ← #3 (local conversion) ← #5 (Music.app integration) ← #4 (cleanup) ← #12 (four-album acceptance)`.

Do not interpret this list as merge authorization. Inspect branch heads, the current review policy, CI and any new commits before proposing integration. The first milestone is to integrate safely and re-verify at the resulting source SHA, without destructive rebase/force-push.

**Reference PR:** [Phase 11 four-album acceptance, #12](https://github.com/raelldottin/tunory/pull/12).  
**Release baseline:** [Deployment requirements](deployment-requirements.md).  
**Source of engineering truth:** [AGENTS.md](../AGENTS.md).

## 4. Delivery strategy

Ship in **dependency order**, using evidence gates instead of speculative calendar dates. The milestones below are recommended releases; dates, budgets and distribution scopes require owner selection.

| Milestone | User outcome | Priority | Dependency | Release gate |
| --- | --- | --- | --- | --- |
| **M0 — Integrate and prove** | The real signed macOS app can safely complete the existing local-file workflow | P0 / Now | Open stacked PR chain, human authorization | Fresh integrated build, GUI drive, live Music.app proof on disposable material |
| **M1 — Local Music v1** | Import whole albums without a streaming subscription | P0 | M0 | Four-album live scenario, duplicate safety and second-run no-op |
| **M2 — Playlist Care** | Audit and clean duplicate playlist entries safely | P1 | Proven playlist read/mutation boundaries | Preview, backup/undo plan, explicit apply, fresh verified result |
| **M3 — Text-to-Playlist** | Create a playlist from a written mood or activity prompt | P1 | Track index and candidate ranking | Hallucination-resistant resolver, human preview and accepted playlist |
| **M4 — Voice-to-Playlist** | Describe mood and request playlists using voice | P2 | M3 + privacy/permission review | Tested speech accuracy, confirmation, no automatic writes |
| **M5 — Service Expansion** | Support Apple Music and qualified Spotify workflows | P2 / gated | Provider adapter contracts and legal/API access | Provider-specific permissions, quotas, compliance, real-account acceptance |
| **M6 — Cross-device and quality** | Consistent iOS/macOS experience, personalization and trusted releases | P3 | Stable macOS product and platform design | Separate device, privacy, UX and distribution proof |

### M0 — Integrate and prove the current engineering work (P0)

**Scope**

- Reconcile `main`, `dev` and PRs #1, #2, #3, #5, #4 and #12. Review their dependency sequence and land only specifically approved changes via the enforced PR process. Re-run CI and tests on the *integrated* SHA; old branch test results do not certify a merge.
- Finish GUI runtime acceptance for the signed app that visibly contains **Local Files**. Validate selecting multiple folders, the destination powerbox grant, denied access, partial failure and saved recovery.
- Prove real Music.app read-only scanning under Transparency, Consent and Control (TCC), then—under a separate narrowly scoped owner approval—import disposable files and independently verify the resulting local library state. Do not change the owner's real music collection without that approval.
- Verify effective App Sandbox, user-selected read/write access and Apple Events entitlements on Debug and Release products. Do not weaken sandboxing to clear tests.
- Rerun environment-blocked GUI XCTest, capture reproducible results or label the precise blocker. Preserve the app icon; rebuild the release candidate from the integrated revision.
- Reconcile the app's declared macOS 27.0 deployment minimum and arm64-only earlier archive with the intended tester audience. Verify current Apple tooling and build identity rather than silently expanding support.

**Exit:** integrated code; clean CI and exact-commit review; signed GUI powerbox proof; verified disposable Music.app import; no unexpected user-library mutations; explicit release-go/no-go. If owner-only steps remain, mark **BLOCKED**, not done.

### M1 — Subscription-free Local Music v1 (P0)

**Scope**

- **Input:** Multiple album folders, one parent folder and selectable files. Recursive discovery, multi-disc albums and large batches. Report unsupported, corrupt or rights-restricted media clearly.
- **Inspect:** Actual codec/container, duration, sample rate, channel layout, tags, artwork, album artist and track/disc numbers. Never trust extensions alone.
- **Deduplicate before conversion:** Inspect actual accessible Music.app library entries. Classify exact byte twins, conservative verified cross-format matches, possible duplicate/alternate recording, missing and uncheckable. Do not use metadata or SHA-256 alone as universal identity.
- **Convert:** Use existing in-process Apple AVFoundation/Core Audio pathway; **AAC 256 kbps reference** and optional **ALAC for lossless sources**. Preserve original files, metadata and artwork when representable. Avoid lossy-to-lossy transcodes and unnecessary conversions.
- **Review and import:** Show album-level counts before writes, allow explicit conflict decisions, recheck before each add, journal attempts, and verify actual Music.app identity and grouping after imports.
- **Recover:** Partial batches resume through fresh-read reconciliation, never blind re-add; existing destination media is never overwritten without proven ownership and a safe policy.
- **Experience:** Distinguish `Already in Music`, `Needs review`, `Will convert`, `Ready to import`, `Imported`, `Skipped`, `Uncertain` and `Failed`. Offer an import history and per-album results.
- **Non-goals for M1:** DRM removal; importing streaming audio as files; iOS Music.app database writes; server-hosted transcoding.

**Acceptance scenario:** four real FLAC albums, 40 recordings, 13 verifiably existing, 27 missing → 27 approved additions, 13 skips, zero unintended duplicates, original checksums unchanged, album metadata intact. Running it again adds zero tracks. Ambiguous cases deliberately go to review instead of forcing those numbers. Automated fake-library results already exist in PR #12; **live signed-app proof is the missing graduation step**.

### M2 — Playlist Care and Duplicate Cleanup (P1)

**Scope**

- Choose a playlist and scan in read-only mode. Distinguish **duplicate entries of one provider ID**, **different IDs for a provably identical recording**, and **look-alikes that may be distinct** (live/remaster/clean/explicit/alternate mix).
- Preview exactly which occurrence will be retained, what would be removed, current ordering and any limitations of the selected service. Default to **no changes**.
- Capture a reversible playlist snapshot/export (identifiers, positions, metadata and provenance) before any removal; offer restore/undo only if the provider permits and the state is still safe.
- Apply only specifically selected removals with fresh playlist reads, provider-safe positional semantics, concurrency/divergence checks and an append-only audit log.
- Include `Analyze only` and `Apply reviewed changes` modes. For local libraries, playlist cleanup must **not delete the actual song file**.
- Support duplicate reports and exports before attempting automation on a provider without a validated deletion API or rights.

**Acceptance:** deterministic scenarios for exact duplicate entries, order preservation, concurrent edits, 10k-item pagination, unauthorized playlist, declined confirmation, interruption and idempotent re-scan. Post-change readback must show the expected sequence with no unrelated differences; uncertain states stop without claiming success.

### M3 — Natural-language Playlist Creation (P1)

**Scope**

- A prompt composer accepts mood, setting, energy, era, genres, languages, duration, explicit-content preference, artists to include/exclude and user-specified constraints. Example: “A moody jazz night, mostly instrumental, under one hour.”
- Split the workflow into (1) **intent interpretation**, (2) **eligible source discovery**, (3) **candidate scoring**, (4) **recording-level resolution**, (5) **preview/edit**, (6) **authorized creation** and (7) **verification**.
- Begin with **local-library-only** candidate discovery: no streaming subscription, no external LLM necessary for typed filters. Offer an on-device or user-consented LLM route for richer intent, depending on model feasibility.
- AI outputs structured, validated **playlist intent**—not provider IDs treated as facts. Real recorded tracks come only from deterministic lookup. Show missing/unavailable tracks, provenance, duplicate exclusion and explanation of why each track was proposed.
- Add playlist duration targets, ordering, intentional transitions, maximum repeats, seed artists and saved reusable prompts/recipes.
- Support a no-write draft/preview and the ability to substitute, pin, reorder or exclude songs.
- Do not promise the same recordings exist on every provider; resolve separately per eligible provider and preserve differences visibly.

**Acceptance:** a reusable offline rule-based baseline; prompt-to-intent tests, adversarial/hallucinated artists, insufficient-library cases, duration bounds, explicit-filter enforcement, deterministic ranking tests, all-invalid suggestion cases, user-canceled requests and signed-app acceptance. Model text is never directly passed to mutation APIs.

### M4 — Voice-driven Music Intent (P2)

**Scope**

- Push-to-talk voice input and clearly visible recording indicator; transcription, correction and explicit confirmation of recognized intent.
- “What mood are you in?” and “What are you interested in?” conversational prompts, with optional follow-up questions for genre, tempo, language and length.
- Prefer on-device speech recognition when reliable and available for supported locale/device. Any remote speech or LLM processing requires opt-in, purpose disclosure and a deletion/retention contract.
- Use the exact M3 playlist-plan-and-verify engine; voice is another **input modality**, not an alternative mutation engine.
- Include accessible text fallback, subtitles/transcript editing, permission denial paths, multilingual evaluation and silence/background-noise handling.
- Never auto-commit a playlist or delete duplicates on a recognized voice utterance alone.
- **Spotify restriction:** do not expose Spotify voice-control functionality unless the actual Spotify Developer Policy permits the specific design or Spotify provides written approval. Voice-to-local and appropriately authorized Apple Music flows are separate product candidates.

**Acceptance:** microphone-permission state machine, cancel/no-audio tests, transcription accuracy across supported languages and noisy environments, user-confirmed intent, no background recording and zero writes before confirmation.

### M5 — Provider expansion: Apple Music and Spotify (P2; policy-gated)

**Apple Music streaming**

- Preserve existing MusicKit/Apple Music catalog transaction and recovery contract. Make streaming capability conditional on active user authorization and required service subscription.
- Support source eligibility, search and match review, playlist-create/append, exact IDs and final playlist readback. A local Music library workflow remains independently available when streaming access is missing.
- Do not conflate a Music.app local persistent ID with a MusicKit catalog identity. Apply separate controls for local file import versus Apple Music streaming library changes.

**Spotify experimental adapter**

- Start with a read-only, **manual text/UI-led** developer experiment for an allowlisted account. Investigate OAuth Authorization Code with PKCE, scopes, track search, owned-playlist read, provider-specific identities, rate/quota handling and safe write APIs.
- Spotify currently limits **Development Mode to five authorized users**, requires the app owner to have Premium, and reserves broad extended access for qualifying organizations (published criteria include 250,000 monthly active users). Consequently **public Spotify support is not an unconditional roadmap commitment**.
- The [Spotify Developer Policy](https://developer.spotify.com/policy) prohibits voice-enabled SDAs that control Spotify and ingestion of Spotify Content into AI models, and restricts mixing/integration with other services. Do not send Spotify catalog metadata/audio into a model, train on Spotify data or claim a unified cross-service playback product without a separate compliance decision.
- Candidate architecture: an LLM may interpret **the user's own words** into abstract intent where lawful and consented, but Spotify content stays within a deterministic provider adapter. Even that proposed separation is **subject to written policy/compliance review before user-facing release**.
- Keep Spotify feature flags disabled outside authorized personal/development use until access, policy and distribution paths are verified. No copying Spotify tracks into a local music library.

**Provider contract / acceptance**

- Typed `MusicSource`, `RecordingIdentity`, `PlaylistIdentity`, `PlaylistSnapshot`, `PermissionState` and capabilities, with per-provider adapters for discovery, resolution, list/edit and readback.
- Track each provider's actual support for delete/reorder/replace; absent permissions → read-only/unsupported, never a simulated success.
- Account disconnect must revoke/clear stored credentials and stop scheduled actions.
- Test account expiry, quota exhaustion, geographic unavailability, duplicate playlist names, external edits and partial writes.
- A `PlaylistBlueprint` can be shared as user intent, but actual playlists, rights and identities remain provider-specific.

**External requirements checked 2026-11-03:**
[Spotify quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes),
[Spotify February 2026 API migration](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide),
[Spotify July 2026 quota changes](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates),
[Spotify policy](https://developer.spotify.com/policy),
[Apple MusicKit](https://developer.apple.com/musickit/).
Recheck at implementation and release time; provider rules change.

### M6 — Personalization, multi-device and release quality (P3)

- **Personalization:** local-first preference memory (pinned/blocked artists, skipped songs, favorite moods, repeated contexts), opt-in; clear controls to inspect/delete. No unconsented behavioral profiling or Spotify-data model training.
- **Playlist recipes:** recurring templates, shareable *intent* text/JSON and explicit rebuild, not unattended background mutation. Scheduled automatic changes require a separate permission and concurrency design.
- **Collection management:** large-library performance, incremental file indexing, external-drive availability, albums with compilations and box sets, non-English metadata, artwork repair preview, audit logs and import history.
- **iOS/iPadOS:** independent product scope for voice, playlist planning and permitted MusicKit capabilities. Do not promise macOS Music.app automation, full arbitrary local-library import, or identical file privileges on iPhone. Prove supported platform-specific access.
- **Offline experience:** local import, analysis, local search and rule-based playlist draft must work without service credentials. Cloud/LLM-dependent features report offline unavailability without blocking local tasks.
- **Distribution:** expand from selected macOS internal TestFlight to further channels only after an explicit owner choice, device compatibility, privacy policy, support contact and G1–G8 release evidence. Maintain app icon identity already merged to `main`.
- **Business model:** research pricing only after retention and support costs are measured; do not introduce subscriptions, in-app purchases or a backend as an unapproved architectural assumption.

## 5. Proposed UX and information architecture

The UI should explain capability, authorization and risk before surfacing a primary action:

| Workspace | Primary purpose | First milestone |
| --- | --- | --- |
| **Home / Discover** | “What do you want to hear?” prompt, saved drafts, shortcuts to recent playlists | M3 |
| **Local Music** | Select albums/files, inspect, deduplicate, convert, import and verify | M0–M1 |
| **Playlists** | Browse eligible playlists, inspect duplicates, build/review/clean | M2 |
| **Create** | Mood, activity, duration and source-aware playlist builder | M3 |
| **Voice** | Push-to-talk input and transcript confirmation | M4 |
| **Connections** | Distinct Music.app/local, Apple Music catalog and Spotify states; scopes and account controls | M1, M5 |
| **Activity / Recovery** | Journaled work, uncertainty, retry/reconcile, per-track proof | M0 onward |
| **Settings / Privacy** | Conversion profiles, model processing choices, data retention, accessibility, permissions | M1 onward |

These are **information-architecture targets**, not instructions to replace the current UI wholesale. Reuse native SwiftUI patterns, consistent design tokens and the existing app icon. Release each screen only when the corresponding backend contract is proven.

### First-run decision tree

1. **No subscription?** Offer Local Music with no network authorization.
2. **Local library granted?** Explain Music.app access separately from Apple Music streaming.
3. **Streaming account connected?** Show only eligible service-specific actions.
4. **AI/voice requested?** Ask for relevant processing/microphone consent before collecting or transmitting data.
5. **A mutation requested?** Show a concrete preview, target source and what will change.
6. **After any action?** Show verified result, partial/uncertain outcomes and available recovery.

## 6. Engineering architecture and dependency map

The architecture should grow by *contract*, not by rewriting the existing proven Apple Music engine:

- **Domain:** user intent, provider-qualified identity, album/track metadata, duplicate evidence, ordering, permissions, playlist blueprint, mutation plan, recovery policy and verification evidence.
- **Application:** orchestrated workflows for scan → reconcile → convert → import; scan → preview → dedup; prompt → plan → resolve → verify.
- **Infrastructure:** separate LocalFile/Core Audio, Music.app Apple Events, Apple Music MusicKit/REST, experimental Spotify Web API, speech, LLM and secure persistence adapters.
- **Presentation:** SwiftUI macOS-first screens, platform-adapted controls, user-confirmation and accessible result/recovery views.
- **Quality:** deterministic injected adapters, test fixtures and synthetic tracks, signed-app permissions, separate authorized disposable writes and source-SHA/CI provenance.

**Important seams**

| Seam | Contract |
| --- | --- |
| Source identity | `local:<content-or-library-id>`, `apple-music:<catalog-id>`, `music-app:<persistent-id>`, `spotify:<uri>` are conceptual examples; use typed structures, not string concatenation as the production identifier schema |
| Matching | Evidence tiers: byte-identical, verified cross-encoding where defensible, likely/metadata collision, incompatible, unknown. Never blindly equate same title with same recording |
| Planner | Produces structured desired sequence and provider-specific candidate sets. Cannot issue a write |
| Transaction | Input is an explicit approved plan and current verified state; emits journaled attempted/verified/stopped outcomes |
| Recovery | Fresh reads plus invariant checks decide resume/no-op/stop; unsafe or unavailable state fails closed |
| Privacy | Secrets in Keychain; minimum provider data; user-approved model input; recording disabled except during visible session |
| Observability | No sensitive titles, credentials, local file paths or raw voice transcripts in telemetry by default; local diagnostic export is redacted |
| Compliance | Provider terms, usage scopes and permitted data flows are explicit feature gates |

**Dependency path:** M0 integration → M1 stable local inventory / provider-qualified identity → M2 playlist mutation safety + M3 playlist planner → M4 voice input. M5 Spotify can be investigated independently but **must not block M1–M4 local and eligible Apple Music delivery**.

## 7. Prioritized, implementation-sized backlog

Use one issue/goal per independently verifiable slice; research and verification workers may run in parallel, but only one worker should mutate the same integration branch.

| ID | Slice | Priority | Verification exit |
| --- | --- | --- | --- |
| TUN-001 | Reconcile stacked PRs and release candidate source of truth | P0 | CI/review on integrated SHA, no history loss |
| TUN-002 | Signed macOS Local Files GUI + security-scoped folder read/write | P0 | Real GUI file picker and verified AAC/ALAC output |
| TUN-003 | Real Music.app read-only survey and bounded live import | P0 | TCC + explicit approved disposable writes + fresh readback |
| TUN-004 | Four-album repeat-run and adversarial duplicate acceptance | P0 | Real library: expected additions/skips; second run 0 adds |
| TUN-005 | macOS internal TestFlight candidate containing icon + local import | P0 | Fresh archive/export, owner-approved upload and tester install proof |
| TUN-006 | Local Music import history, errors and recovery UX | P1 | Resume/unknown/permission-denied cases proven |
| TUN-007 | Playlist inventory + duplicate report (read-only) | P1 | Exact/likely/unknown tiers, no writes |
| TUN-008 | Preview/confirm/apply playlist duplicate removals | P1 | Reversible plan, no unintended removals, independent readback |
| TUN-009 | Offline local track search/ranking and playlist draft | P1 | Deterministic filters, valid candidates, offline |
| TUN-010 | Typed mood/activity prompt interpreter and structured planner | P1 | Hallucination and user-intent validation; no direct writes |
| TUN-011 | Local and Apple Music destination-specific playlist realization | P1 | Reviewed playlist, provider-qualified IDs, ordered verification |
| TUN-012 | Voice capture, transcript correction and permission UX | P2 | Consent/no-background-recording tests |
| TUN-013 | Privacy/model controls, BYO/provider/on-device feasibility decision | P2 | Data flow threat model, redact/delete behavior |
| TUN-014 | Spotify access, policy, endpoint and business feasibility gate | P2 / blocked pending approval | Written go/no-go; no production distribution assumptions |
| TUN-015 | Spotify read-only experimental adapter | P2 / gated | Approved account, scoped access, quota/error handling |
| TUN-016 | Spotify manual playlist mutations and verification | P2 / gated | Provider-permitted write, fresh readback, no prohibited AI/voice behavior |
| TUN-017 | iPhone/iPad experience and source-specific capability matrix | P3 | Physical-device and separate distribution proof |
| TUN-018 | Large-library reliability, performance and accessibility polish | P3 | Defined latency, memory, VoiceOver, locales and recovery gates |

This table is a **planning backlog**, not a claim that GitHub Issues or Hermes cards were created.

## 8. Release and validation gates

Do not silently graduate a milestone to `done` when its tests are mocked or its user-facing behavior is blocked. Apply the existing deployment requirements G1–G8 and capture separate evidence for:

1. **Source and policy:** correct PR stack, exact commit review, clean or explicitly protected-dirty Git state, license/provider compliance.
2. **Deterministic tests:** Swift package, app-hosted tests, CLI safety tests, audio fixtures, duplicate classification and transaction recovery.
3. **Signed builds:** macOS Debug/Release, generated entitlements, app identity, signing verification, SDK and minimum OS.
4. **GUI:** actual user-selected files and destination folder, all permission states, Accessibility/keyboard/VoiceOver, local-only fallback and realistic error display.
5. **Authorized live writes:** disposable files/playlists, before/after evidence, no unrelated changes, partial failure and repeated no-op.
6. **Privacy and security:** scoped credentials, mic controls, local path and transcript redaction, provider-data boundaries.
7. **Distribution:** local export is not TestFlight upload; App Store processing is not tester installation; physical device proof is not simulator proof.
8. **Owner acceptance:** exact candidate, enabled features, user experience, support policy and approved destination/audience.

Evidence report statuses must be **PASS / FAIL / NOT ATTEMPTED / BLOCKED**. Distinguish demo-only, mocked, signed-app runtime, authorized live account, uploaded and installed tester proof.

## 9. Product measurement and quality targets

These are **proposed targets to measure**, not measured current metrics.

| Metric | Initial success definition | Guardrail |
| --- | --- | --- |
| Four-album task completion | User can complete supported local workflow with one final review, without manual drag/drop | Zero unexpected track/file modifications |
| Duplicate precision | No automatically skipped distinct recordings in accepted adversarial fixture suite | Ambiguity goes to review |
| Idempotent retry | Re-running a completed import or playlist transaction adds/removes zero unintended items | Uncertain state never blindly replays writes |
| Verified playlist success | Successful flows end in independently read-back, exact approved sequence | API acknowledgment alone not counted |
| Time-to-first-playlist | Track median from starting prompt to verified playlist, by local vs provider path | Never trade away confirmation to make it faster |
| AI suggestion usability | Accepted tracks / suggested tracks and user edits before save | No invented identifiers or unlicensed Spotify data to LLM |
| Voice quality | Share of spoken intents confirmed without correcting the transcript | Mic off when not in active session |
| Reliability | Error, crash and recoverable interruption rates by app version | Distinguish connectivity, permissions, provider restrictions |
| Privacy | No unintended audio upload, credential logging or provider content/model mixing | User can inspect/disconnect/delete relevant data |

Set quantitative SLOs only after actual pilot instrumentation and baseline results; synthetic tests are insufficient.

## 10. Major risks and decisions

| Risk or decision | Default direction | Owner/engineering gate |
| --- | --- | --- |
| Local vs streaming scope | Local workflows are complete products on their own; service integrations optional | Do not block on Apple Music subscription |
| Which conversion default? | AAC 256 kbps as reference; ALAC explicit lossless choice | Revisit after usability/storage evidence |
| Cross-format identity | Conservative metadata + available audio evidence; review when unsure | False skips/unintended imports are release blockers |
| Removing duplicates | Preview and explicit selected actions; preserve song files | Provider-specific restoration and concurrency acceptance |
| Spotify product viability | Personal/read-only experiment first; public integration conditional | Account access, legal/API approval, 5-user cap / extended-mode eligibility |
| Spotify + voice / AI | Not ship as designed without explicit policy allowance | Spotify prohibits voice-controlled SDAs and Spotify Content ingestion into AI |
| Model choice and cost | No mandatory LLM or server for local functionality | Owner decides on-device, user-key or hosted model after privacy/cost study |
| Subscription / monetization | Do not assume a recurring charge | Owner pricing decision after retention and expenses measured |
| Launch platform | macOS internal TestFlight selected first | Fresh integrated candidate, not historical archive |
| iOS local library parity | No assumption of macOS file or Apple Events access | Separate feasibility and physical-device acceptance |
| Unmerged code and branch policy | Preserve stacked PRs and review enforcement | No automatic merge, force-push or ruleset bypass |
| Release version/support scope | Not inferred from an existing `1.0 (1)` build | Confirm version, tester group, OS compatibility, support and privacy URL |

## 11. Next recommended execution

**First:** perform a narrowly bounded integration-and-acceptance goal for TUN-001 through TUN-005, reusing PR #12's existing implementation and verification instead of opening a duplicate build swarm. Independently verify the current PR stack and owner-only permissions; do not perform live Music.app mutations until explicitly authorized.

**Second:** once signed local import is reliable, prototype **Playlist Care / duplicate report** as a read-only feature. This addresses a recurring user pain while minimizing external AI or streaming dependencies.

**Third:** prototype **text-to-playlist using local music**, proving safe candidate selection and human review before adding LLMs, speech or additional services.

**Fourth:** independently investigate Spotify's access and policy terms, and keep any public-facing or voice-enabled Spotify functionality disabled unless allowed.

For agent execution, reuse the `tunory` Kanban board's existing builder, verifier and synthesizer profiles; do not create a standalone goal and a duplicate swarm for the same objective. Preserve ECC preflight, one code-writer per branch, independent verification and explicit human acceptance gates.

---

## 12. Source ledger and maintenance

**Repository sources (reviewed 2026-11-03):**

- [README and current product baseline](../README.md)
- [Agent and engineering policy](../AGENTS.md)
- [Apple Music engineering retrospective](apple-music-integration-retrospective.md)
- [Phase 9 beta and recovery](phase9-beta-productization.md)
- [GitOps implementation and review checklist](gitops-next-actions.md)
- [Deployment requirements](deployment-requirements.md)
- [macOS internal TestFlight archive/export record](releases/macos-internal-testflight-2026-10-21.md)
- [Icon asset decision and proof](app-icon.md)
- [PR #12: four-album import and independently rerun evidence](https://github.com/raelldottin/tunory/pull/12)

**External provider references (checked 2026-11-03; subject to change):**

- [Apple MusicKit](https://developer.apple.com/musickit/)
- [Spotify developer quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Spotify 2026 Development Mode migration](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
- [Spotify July 2026 quota update](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates)
- [Spotify Developer Policy](https://developer.spotify.com/policy)

**Maintenance contract:** update the baseline and milestone status only against merged source, current PR evidence or real distribution data; keep proposed targets separate from measured results. Do not overwrite historical reports or silently describe a feature-branch implementation as public availability.
