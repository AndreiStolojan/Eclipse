# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem.

Include what you found, how to reproduce it and which version or commit you tested. I will reply as soon as I can and keep you updated until it is fixed.

## Scope

Eclipse is a local app. The parts most worth a look:

- the local socket for Sotto and script notices (`Sources/Notch/NotchSocket.swift`, `docs/socket.md`), open only while either integration is on;
- the Spotify sign-in, a loopback listener on `127.0.0.1:43821` during sign-in only (`Sources/Notch/NotchSpotify.swift`);
- the T3 Code link and its token in the Keychain (`Sources/Notch/NotchT3.swift`, `docs/t3-code.md`);
- `install.sh`, which builds and installs the app.

Builds are signed ad hoc unless you set `ECLIPSE_CODESIGN_IDENTITY` to your own certificate; the README explains both.
