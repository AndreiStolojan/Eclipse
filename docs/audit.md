# Repository audit

Audit started on 29 October 2026 against the working tree on `feat/cli-notice-design`, including the existing uncommitted script-notice feature. The user authorized repairs to that working tree. Existing feature changes were preserved. Publishing and merging are tracked separately from this audit report.

Four Claude Opus 5.5 agents, each with medium effort, implemented the repair batches. The parent agent integrated the checks, updated documentation, repaired diagnostic and preference-recovery paths, and addressed the final review findings. A fifth Opus 5.5 medium agent completed an independent review of the repairs and the remaining production-code coverage. Static review and implementation are complete. The user deferred Swift compilation and real Mac validation until after the audit; they remain explicitly unverified.

## Findings

Twenty-two findings have code fixes: one High, twelve Medium and nine Low. Their validation differs, as recorded below. A code fix is not a claim of a passing Mac test.

Severity describes the effect and the conditions needed to trigger it. A manually corrupted local preference has a different exposure from a normal app action or an external response. These findings do not establish remote code execution or a bypass of macOS authentication.

| ID | Severity | Finding and trigger | Repair | Validation |
| --- | --- | --- | --- | --- |
| A01 | High | `scripts/render.sh` deleted all of `docs/images`, including Sotto and notification images that it did not regenerate. | Replace only the eight managed files; require all eight renders before replacing any. | Reproduced and checked in a disposable repository with mocked tools. |
| A02 | Medium | Rendering a clean checkout failed because the build log was opened before `.build` existed. | Create `.build` before redirecting the build log. | Mocked clean-checkout check passes. |
| A03 | Medium | `scripts/check.sh` required GNU `timeout`, outside the documented Xcode requirements. | Run each check under a Python alarm that survives `exec`; restore signal defaults first. | Mocked pass, timeout and failure-message checks pass on Linux. macOS validation pending. |
| A04 | Medium | An enormous stored `clipboardLimit` reached `Int` conversion and could crash startup. Other sizes and durations also accepted values outside the UI ranges. | Clamp all 28 numeric settings to their slider ranges during load. | New `NotchSettingsChecks.swift`; compilation pending. |
| A05 | Medium | A Spotify `Retry-After` such as `nan`, `inf` or `1e300` reached `Int(wait)` and could trap. | Substitute five seconds for non-finite values and clamp finite delays to 1...3600 seconds before date arithmetic and logging. | Five scripted transport cases added to `NotchLikeChecks.swift`; execution pending. |
| A06 | Medium | A T3 detail fetch could publish after disconnect, thread removal or reconnection. Its old cleanup could also alter the newer connection's fetch bookkeeping. | Give fetches a connection generation and check it before publishing or cleaning up. Require the thread to remain present. | Control flow reviewed; Mac integration checks pending. |
| A07 | Medium | A short title with thousands of combining marks could exceed the socket's byte limit. The CLI could exit successfully although the server rejected the line. Re-encoding stdin could also grow an initially valid payload. | Measure the encoded line before connecting and reject lines over 4096 bytes. | Both input paths covered in the real-CLI Python check; Swift CLI build pending. |
| A08 | Medium | A continuously writing or connecting same-user client could keep a socket callback looping on the serial IO queue, delaying replies and synchronous shutdown. | Accept one connection or read one bounded chunk per callback, allowing queued work to run between callbacks. | Control flow reviewed; sustained-traffic Mac test pending. |
| A09 | Low | A socket path containing NUL silently named a different path. Command-line arguments cannot contain NUL, but a Swift caller could supply it. | Reject NUL in socket addresses. | Parser check added; execution pending. |
| A10 | Low | The release entitlement scan covered only top-level embedded code, despite promising to check nested helpers. No such helper is embedded today. | Search code bundles recursively. | Bash syntax and ShellCheck pass; actual codesign validation pending. |
| A11 | Low | A symlink at the installed app path was rejected only after downloading and building. | Refuse it during destination selection. | Code reviewed and ShellCheck passes; installer execution pending. |
| A12 | Medium | Revoke during T3 credential issuance could refill the cache with the revoked token. A quick reconnect could also have its new Keychain item deleted by the older revocation. | Track credential generations and serialize later issuance behind outstanding revocation. | Control flow reviewed; real Keychain and T3 integration checks pending. |
| A13 | Medium | The T3 CLI deadline sent only SIGTERM, so an uncooperative child could hang forever. AppleScript read stdout and stderr sequentially, allowing a full stderr pipe to stall it. Descendants retaining a pipe could also hold either caller. | Share `NotchProcess`: drain both streams, escalate SIGTERM to SIGKILL, and bound the wait for inherited pipes after exit. | Three subprocess checks added; compilation and execution pending. |
| A14 | Low | A cancelled travel plan could start a MapKit operation after its awaited location arrived. | Check cancellation immediately after the location fix. | Control flow reviewed; Mac validation pending. |
| A15 | Medium | A shelved image overwritten at the same path could reuse the previous version's thumbnail for the session. | Include modification time in the image-preview cache key. | Code reviewed; overwrite and reopen check pending on Mac. |
| A16 | Low | A cancelled detached image decode could publish an old screenshot or thumbnail after a newer load finished. | Check task cancellation before assigning screenshot, shelf and agent thumbnail results. | Code reviewed; rapid-screenshot check pending on Mac. |
| A17 | Low | A media confirmation could update reports after cancellation. A completed transport command could start another read after media stopped or the followed player changed. | Check cancellation before refreshing a confirmation; require a running service and the same followed app before reading it. | Code reviewed; lock, sleep and player-switch checks pending on Mac. |

`SECURITY.md` now describes both socket opt-ins. The lock-screen documentation now matches the three delayed reconciliation attempts in the implementation. No appearance, layout or UI text was redesigned.

Further findings were confirmed while reviewing diagnostics and preference recovery:

| ID | Severity | Finding and trigger | Repair | Validation |
| --- | --- | --- | --- | --- |
| A18 | Medium | Shelf rendering wrote `notes.md` and a fixed screenshot name directly into the user's temporary directory, then removed them. A preexisting file with either name could be overwritten and deleted; concurrent renders could also collide. | Create a unique temporary fixture directory, keep stable filenames inside it and remove only that directory. | Source reviewed; a real renderer run remains pending. |
| A19 | Medium | `--probe`, described as read-only, started a normal experience using the user's preferences. It could ask for Accessibility, capture the clipboard, start opted-in integrations and advance or finish a persisted timer. | Copy settings into a disposable suite, disable those services and travel lookups, and pause browser lookups. Read-only service observations use the disposable suite. | Startup paths traced through `NotchExperience`; Mac prompt, Keychain and timer preservation checks pending. |
| A20 | Low | A wrong JSON type or unsupported enum in one preference reset every setting to defaults. | Replace only the failed top-level field with its default, retry each field at most once, and preserve valid unrelated preferences. | Added malformed scalar, null, enum, nested enum and unreadable-document cases to `NotchSettingsChecks.swift`; execution deferred to Mac. |
| A21 | Low | A file saved during thumbnail decoding could leave old pixels cached under the new modification date. Both image caches read the version only after decoding. | Capture the version before opening the image and store the result under that captured key in `NotchImagePreview` and `NotchThumbnails`. | Final review finding addressed; ImageIO race reproduction deferred to Mac. |
| A22 | Low | The Spotify loopback check read results written by a detached client after a fixed 300 ms sleep. That did not synchronize shared memory or guarantee response completion. | Check that the valid callback arrived, then join the client with a dispatch group before inspecting its results. | Test control flow reviewed; Swift execution deferred to Mac. |

## Scope and coverage

The initial pass inventoried all application sources, CLI files, scripts, project configuration, documentation and checks. The detailed reviews cover settings, socket parsing and lifecycle, Spotify authorization and HTTP handling, T3 connection and credentials, calendar and travel tasks, screenshot and download watchers, clipboard retention, shelf bookmarks, media reports, state transitions, geometry, window visibility, runtime private API lookup, build signing and installer replacement.

The final independent review covered the remaining media/browser pure logic, view tasks and callbacks, timer/calendar views, Markdown, artwork and wave logic, plus `NotchProcess` and the repair diffs. The parent reviewed the settings UI, app startup and diagnostic/fixture paths. New checks and changed test sections were reviewed; existing long scenario suites were inspected for coverage, isolation and side effects, rather than independently proving every unchanged assertion. Inventory is not counted as a detailed source review.

Binary and project checks cover repository JSON, both Xcode plist files, the Xcode scheme, icon SVG XML, all 34 PNG files' chunk checksums, and asset catalog filename references. The README's local targets exist. Assets were not regenerated or changed during the audit.

The only external package remains pinned to `cf30c4f1af29b5829d859f088f8dbdf12611a046`. Its upstream implementation was not included in this local audit. The redistribution limitation already documented in `NOTICE.md` remains; this audit does not clear distribution of built binaries.

## Validation

The host is Linux. It has Bash, Python and ShellCheck, but no Swift compiler, AppKit, Xcode or macOS WindowServer.

| Check | Result |
| --- | --- |
| Bash syntax for production scripts and the new script checks | Passed. |
| ShellCheck for `scripts/*.sh`, `scripts/notch/NotchScriptChecks.sh` and `install.sh` | Passed. |
| `scripts/notch/NotchScriptChecks.sh` | All nine assertions passed in disposable repositories. |
| Integrated `scripts/check.sh` | The nine script assertions pass, then the first Swift compile fails with `swiftc: command not found`. No Swift check has passed here. |
| `scripts/build.sh` | Refused Linux with `Eclipse requires macOS and Xcode.` No app build has passed here. |
| Plist, JSON, scheme, SVG, PNG and asset references | Passed. |
| `git diff --check` | Passed after integration. |

`check.sh` includes the new settings check and script checks. Every compile group that uses `NotchWebSource` or `NotchT3` also includes the new `NotchProcess.swift`. Xcode's synchronized source folder includes it automatically.

The script harness uses stub `xcodebuild`, `swiftc` and `defaults` commands. It proves script control flow and file preservation, not Xcode compilation, image rendering, codesigning or macOS behavior. Swift checks were written but have not run. No real Mac behavior has been tested in this audit.

## Completion boundary

All five delegated tasks are finished. The final reviewer found the thumbnail version race, which is repaired above. The parent also checked preference recovery, diagnostic isolation and test synchronization. The available checks are recorded in this report; no known confirmed finding is left without a code repair.

The user explicitly deferred the unavailable Mac validation. These changes are ready for that validation, not certified for release. This audit does not guarantee that every possible defect or macOS edge case has been found.

## Mac follow-up deferred by the user

Run `scripts/check.sh` and `scripts/build.sh` on the same working tree. Exercise the following before treating the application repairs as verified:

- Connect T3, revoke while issuance is in progress, then connect again. Confirm that the old session is revoked and the new session persists.
- Disconnect or remove a T3 thread while its detail is loading. Confirm that its detail cannot return into a newer connection.
- Overwrite a shelved image and reopen the shelf. Take two screenshots in quick succession and check thumbnail, pixel size and dragged file agreement.
- Press a media transport control, then lock, sleep or change the followed player before the script returns. Confirm that obsolete reads do not start.
- Run socket traffic while disabling the integrations and quitting. Check that shutdown and Sotto replies remain responsive.
- Seed `notes.md` and the old fixture screenshot name in the user temporary directory, run render, and confirm those files survive unchanged. Verify that Sotto and notification documentation images survive too. Review the generated views for accidental visible changes.
- Run `--probe` with integrations and clipboard history enabled in the installed app and with a running timer. Confirm no prompt, credential mutation, capture or timer change occurs.
- Check media playback, permission prompts, lock-screen placement and controls, display changes, Accessibility, EventKit and installer replacement on a real Mac. Existing documentation describes lock-screen behavior that was already unverified before this audit.

## Deferred observations

These are limits or improvement opportunities, not verified vulnerabilities or completed repairs:

- Numeric slider ranges are repeated in settings validation and UI declarations. The lock offset range is also repeated because some check binaries compile settings without lock-screen code. Keep them synchronized.
- Screenshot names intentionally remain remembered until the watcher restarts or changes folders. Existing checks require this to avoid re-reporting an evicted and restored iCloud screenshot. The set can grow with a long session and a large folder; no practical memory failure was reproduced.
- Brightness notification registration follows the first eligible display. A clamshell-to-built-in-display transition needs Mac testing before changing undocumented registration behavior.
- Certificate re-signing currently handles the framework the app embeds. If helpers or dylibs are added later, extend the nested signing step as well as the entitlement scan.
- Shell notice examples intentionally send command text to local in-memory history. A command containing a credential can expose part of it in a notice. Use generic notice text for commands containing secrets.
