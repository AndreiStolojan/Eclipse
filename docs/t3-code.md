# T3 Code in the notch

Eclipse can show what T3 Code's threads are doing: an alert under the closed notch when a thread finishes or needs you, a T3 Code page after Shelf, and a page per thread where questions and approvals can be answered. Checked against T3 Code 0.0.46 nightly (5 October 2026).

## Connecting

The link is off by default. Turn it on in Settings, Connected apps, T3 Code, Connect. The first time, Eclipse runs T3's bundled CLI the way the desktop app starts its server:

```
ELECTRON_RUN_AS_NODE=1 "T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)" \
  ".../Contents/Resources/app.asar/apps/server/dist/bin.mjs" auth session issue --label Eclipse --ttl 365d --json
```

T3 returns a bearer session (`sessionId`, `token`). Eclipse keeps it in the login Keychain (service `ro.andrei.NotchLab.t3code`, or `ro.andrei.NotchLab.beta.t3code` for Eclipse Beta) and never writes it anywhere else. T3 lists it among its sessions as "Eclipse". Revoke on the settings page runs `auth session revoke` and deletes the Keychain item. A token T3 refuses (revoked from T3, expired) is deleted, and the status asks to reconnect.

T3 does not trust loopback: there is no tokenless route, and T3 issues no narrower scope. The token can do what T3's own clients can, so it stays in the Keychain.

## Protocol

Eclipse connects while T3 Code runs (watched through `NSWorkspace.runningApplications`) and the link is on. The address comes from `~/.t3/userdata/server-runtime.json` (`origin`), since the port can change between launches. Eclipse only uses a loopback address there (`http://127.0.0.1`, `localhost` or `[::1]` with a port, nothing else in it) and refuses redirects, so the token never leaves the Mac.

- WebSocket `ws://127.0.0.1:<port>/ws?orchestrationProtocol=2` with `Authorization: Bearer`. Frames are Effect RPC JSON: `{"_tag":"Request","id","tag","payload","headers":[]}` out; `Chunk` (acknowledged with `Ack`, or the stream stalls), `Exit` and `Ping` (answered with `Pong`) in.
- `orchestration.subscribeShell` streams every thread's shell: a `snapshot`, then `thread.updated` and `thread.removed`. Later snapshots carrying `resolvedRepositoryIdentityRoots` only refresh projects.
- A thread's page reads `GET /api/orchestration/threads/<id>/bounded` (header `x-t3-orchestration-protocol: 2`) when it opens, when that thread changes while open, and when a new question or approval appears. A change during a fetch fetches once more afterwards.
- Answers, approvals and Stop go through `orchestration.dispatchCommand`: `runtime-request.respond` with `answers` (keyed by question ID; the option's `value`, or its label; a list for a multiple choice) or `decision`, and `run.interrupt` with `holdQueue`.
- T3 has no link that opens one thread from outside, so Open in T3 brings the app forward.

All decoding lives in `Sources/Notch/NotchAgents.swift`. Unknown fields are ignored, an unknown status reads as idle, and a value that does not decode is skipped, so a newer T3 degrades a row instead of breaking the stream.

## States

The phase follows T3's own `resolveThreadAwarenessPhaseV2` and its sidebar: a pending question is Input, any other pending request but an auth refresh is Approve, a usage limit is Limit, a finished run with a plan ready is Plan, a finished run is Done unless subagents or monitors still work, then Failed and Stopped (interrupted or cancelled). The page lists what T3's sidebar shows: settled threads (T3's Settled shelf) and snoozed ones (until their snooze ends) leave it, and so do subagent, archived and deleted threads. They do not alert either.

Woke follows T3's sidebar too: a thread is Woke once its snooze ends, or earlier when a question, an approval or a finished run wakes it, until it is opened in T3. Eclipse sleeps until the next snooze ends, then lists the thread again and alerts Woke. Snooze on a thread's page offers T3's choices (in 1 and 3 hours, this evening at 18:00, tomorrow and Monday at 9:00) and sends `thread.snooze`; T3 allows it only for a thread that neither runs nor waits for an answer.

A thread entering Done, Input, Approve, Plan, Failed, Stopped or Limit alerts once per run and request. The first snapshot after connecting only records, so threads that finished earlier do not alert; after a reconnect, changes during the gap do. Several threads entering the same state together read as one alert, "3 Done".

Typed answers are not possible from the notch: the panel never becomes the key window, which keeps the keyboard in the app you type in. Answer in T3 brings T3 forward for them.
