# Pi failure notices

This contract lets the Pi worker emit failures that Eclipse can display.
It uses the existing SSH connection over Tailscale and the local Mac socket.
Eclipse adds no network listener. Nothing here enables SSH, installs keys,
changes services or installs Eclipse.

## Producer contract

Emit one UTF-8 notify object per line, at most 4096 bytes including its newline.
The fields and validation rules are the same as [the local socket](socket.md).
Use a stable ID per host and check, such as `pi.<host>.<check>`, up to 64 ASCII
characters from `[A-Za-z0-9._-]`. These examples use `pi` as the host:

```json
{"type":"notify","id":"pi.backup.daily","title":"Pi backup failed","detail":"Repository unavailable","symbol":"exclamationmark.triangle.fill","tint":"red"}
{"type":"notify","id":"pi.backup.daily","title":"Pi backup recovered","detail":"Backup completed","symbol":"checkmark.circle.fill","tint":"green"}
{"type":"notify","id":"pi.service.app","title":"Pi service failed","detail":"Health check failed","symbol":"exclamationmark.triangle.fill","tint":"red"}
```

Recovery uses the same ID as failure, replacing the stale failure in history.
Send transitions rather than every failed probe. Keep details generic. Do
not send credentials, command output, backup paths or logs. Colour does not
give a notice priority over dictation or timers.

## Delivery

On the Mac, build the `notch` CLI and enable Script notices in Eclipse.
With an existing Pi-to-Mac SSH route and the CLI already on the Mac at
`~/.local/bin/notch`, send one event through stdin:

```sh
ssh -T -o BatchMode=yes -o ConnectTimeout=5 mac-host \
  'exec "$HOME/.local/bin/notch" --stdin' < failure.json
```

Replace `mac-host` with the existing SSH alias or Tailscale hostname. The remote
command stays fixed. Event text travels only through stdin, never through
shell interpolation. A producer invoking SSH from code should pass arguments
as an array and JSON as stdin bytes.

`notch --stdin` validates the entire bounded payload before connecting and
accepts only notify, never dictation. It re-encodes the cleaned notice with
the shared parser before writing to the same-user socket. SSH authenticates
the remote login; the socket still checks the Mac user's UID and its existing
folder and socket permissions.

If a dedicated key is added later, restrict it to this fixed command with
no PTY or forwarding. Configuring that key or changing SSH service settings
is separate work. Do not silently create another ingress route when the Mac
is unavailable.

## Failure semantics

- Exit 0 means the CLI wrote to the socket. It does not acknowledge display,
  queue retention or durable delivery.
- Exit 1 means the socket could not be reached or written.
- Exit 2 means invalid CLI input.
- SSH can fail separately when the Mac sleeps, is offline or refuses access.

Keep failures in the Pi's own records even after sending. This integration
is a secondary display with bounded memory, not a reliable incident queue.
The first version has no retry daemon, persistence or display acknowledgement.
No production service or backup settings are changed by this implementation.
