# Local socket and `notch` CLI

Eclipse listens on a Unix domain socket for dictation state from Sotto, the companion dictation app, and for notices from scripts and the terminal. There is no network listener. The socket opens when either Settings > Connected apps > Sotto > Connect or Settings > Connected apps > Scripts > Script notices is on. Both are off by default.

Socket: `~/Library/Application Support/Notch Lab/notch.sock` (the folder keeps the app's old name, so Sotto finds it).

Dictation shows as a small pill under the camera. Script notices appear briefly below it and stay in the Notifications page, available by swiping through the open notch. Click an alert to open that page.

## Script notices

Turn on Script notices to show notices independently of Sotto. An alert stays for eight seconds of visible time; hover or a higher-priority activity pauses that time. Dictation, screenshots, downloads, system indicators, timer completion, T3 alerts and calendar Quick Peeks take priority. A running timer continues counting.

Up to eight alerts, including the current one, wait in arrival order. At capacity, the oldest waiting alert leaves the queue. Alerts older than 60 seconds expire. The Notifications page keeps the latest 20 entries in memory, including alerts that expired or left the queue. Opening that page marks pending alerts seen. The alert's × dismisses only the alert; each history row's × removes that entry, and Clear removes all entries. Disabling Script notices clears the history and removes its page.

A matching `id` updates the existing history row and pending alert. Identical repeats, including identical payloads without an ID, do not add rows, re-alert or extend the current alert. Changed content for an existing ID starts a new alert if its previous alert has finished. Progress updates change in place. Tint changes appearance, never priority.

Notices received while locked or asleep can enter history but do not alert on return. Locking discards pending alerts. No notice text is drawn on the lock screen; no notice history is written to disk. Timestamps in the list show arrival time without a continuously updating clock.

## Dictation

While Sotto records, the notch closes to a 220 × 54 pill with Sotto's bars, which move only when a level arrives. Hovering a recording shows Cancel and Stop either side of the bars; while Sotto processes, the pill reads Transcribing. The notch tells Sotto `presenting true` whenever it is on screen; hidden, asleep or quit, it is `false` or the connection is gone, and Sotto shows its own recorder instead. There is never more than one indicator.

## Protocol

Newline-delimited JSON: UTF-8, one object per line, at most 4096 bytes per line including the newline. Unknown keys are ignored. A line that breaks any rule below is dropped and logged; the connection stays open, except for an oversized line, which closes it.

### Client to notch

| `type` | Field | Rule |
| --- | --- | --- |
| `notify` | `title` | Required. Line breaks and tabs become spaces, other control and bidirectional formatting characters are removed, ends trimmed. Empty after that: rejected. Over 40 characters: cut with `…`. |
| | `detail` | Optional. Same cleaning, cut at 80 characters. Empty: left out. |
| | `symbol` | Optional SF Symbol name matching `^[a-z0-9]+(\.[a-z0-9]+)*$`, at most 64 characters, else rejected. A name macOS cannot draw falls back to a default in the view. |
| | `tint` | Optional, default `white`. One of `white green red orange yellow blue teal purple pink`, else rejected. |
| | `id` | Optional, 1 to 64 characters of `[A-Za-z0-9._-]`, else rejected. The same ID updates an existing history row and pending alert. |
| | `progress` | Optional number, clamped to 0...1. |
| `dictation` | `state` | Required: `idle`, `starting`, `recording` or `processing`. |
| | `level` | Optional number, clamped to 0...1, default 0. |

Only the Sotto opt-in allows dictation. While it is on, the connection that most recently sent a `dictation` message is the dictation client. There is one at a time; a new one replaces the old. When it disconnects, the notch returns to idle. With only Script notices enabled, dictation messages are ignored.

```json
{"type":"notify","title":"Build finished","detail":"42 s","symbol":"hammer.fill","tint":"green","id":"build","progress":0.4}
{"type":"dictation","state":"recording","level":0.42}
```

### Notch to client

Only the dictation client receives anything.

| Line | Meaning |
| --- | --- |
| `{"type":"presenting","available":true}` | Whether the notch shows dictation now. Sent when a connection becomes the dictation client and on every change. |
| `{"type":"stop"}` | The stop button was clicked: finish the recording and insert the text. |
| `{"type":"cancel"}` | Discard the recording. |

### Limits

- At most 8 connections at once; more are closed on accept.
- Per connection, a token bucket of 60 lines per second with a burst of 60. Lines over the limit are dropped. Sotto's 20 Hz levels pass.

## CLI

`./scripts/build.sh` builds the CLI to `.build/notch` next to the app; it is not part of the app bundle. To put it on `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf "$PWD/.build/notch" ~/.local/bin/notch   # from the repository; ~/.local/bin must be on PATH
```

```text
notch [--symbol NAME] [--tint COLOUR] [--id ID] [--progress 0...1] [--socket PATH] [--] TITLE [DETAIL]
notch --stdin [--socket PATH]
```

```sh
notch "Build finished" "42 s" --symbol hammer.fill --tint green --id build
notch "Upload" --progress 0.4 --id upload
```

Options may come before or after the text; `--` ends them, for a title that starts with `--`. It validates with the same parser as the app, sends one line and exits. Exit codes: 0 sent, 1 Eclipse not listening (one line on stderr), 2 invalid input.

`--stdin` reads exactly one notify object, with an optional final newline, and rejects dictation, extra lines, invalid JSON and input over 4096 bytes. It accepts only `--socket` alongside it. The whole input is validated before connecting. Use it to pass JSON through SSH without turning message text into a shell command. See [Pi notices](pi-notices.md) for the contract.

Exit 0 confirms a socket write, not display or durable delivery. Eclipse can drop a notice while its opt-in is off, when rate-limited, or when an alert expires.

## Long commands in zsh

Add to `~/.zshrc`. Commands running 30 s or longer post their command line and duration, with a green checkmark on success and a red xmark with the exit code otherwise. Interactive programs are skipped; edit the pattern to taste. Errors are discarded, so the hook is silent while Eclipse is not listening.

```zsh
zmodload zsh/datetime
autoload -Uz add-zsh-hook

notch_preexec() { _notch_command=$1; _notch_start=$EPOCHREALTIME }

notch_precmd() {
  local code=$?
  [[ -n $_notch_start ]] || return
  local seconds=$(( ${EPOCHREALTIME%.*} - ${_notch_start%.*} ))
  local command=$_notch_command
  unset _notch_start _notch_command
  (( seconds >= 30 )) || return
  [[ $command == (vim|nvim|ssh|less|man|top|htop|claude)* ]] && return
  local duration="$seconds s"
  (( seconds >= 60 )) && duration="$(( seconds / 60 )) min $(( seconds % 60 )) s"
  if (( code == 0 )); then
    notch --symbol checkmark.circle.fill --tint green --id shell -- "$command" "$duration" 2>/dev/null
  else
    notch --symbol xmark.circle.fill --tint red --id shell -- "$command" "exit $code, $duration" 2>/dev/null
  fi
}

add-zsh-hook preexec notch_preexec
add-zsh-hook precmd notch_precmd
```

The CLI cuts the title to 40 characters and turns a multi-line command into one line.

## Security model

- The socket is `0600` inside a `0700` folder. A folder owned by another user, or a symbolic link in its place, stops the socket from starting. A socket file that still answers means another Eclipse is running, and this one does not listen until that instance quits; a stale one is removed.
- Each connection's peer user ID is checked with `getpeereid`; anything other than the user running Eclipse is closed.
- No network listener. Plain text only, with the length, connection and rate limits above.
- Logs (subsystem `ro.andrei.NotchLab`, category `socket`) record connections and rejection reasons, never message content.
- Any process running as the same user can still post notices while enabled, or become the dictation client while Sotto is enabled: report state and receive `presenting`, `stop` and `cancel`. That is the trade-off of a local, same-user socket. The transcript is never sent over the socket; only state and level are.
