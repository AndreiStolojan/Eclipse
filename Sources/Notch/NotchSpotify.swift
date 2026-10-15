import AppKit
import CryptoKit
import Network
import Security
import os

/// Like and Playlist reach Spotify through its Web API, signed in with the Authorization Code flow and PKCE, so no
/// client secret is involved. Eclipse ships no Client ID: each user registers their own app in Spotify's developer
/// dashboard and pastes its Client ID on the Now Playing page. Until then Spotify is left out: its heart and its
/// Playlist button stay dimmed. Once it is set, the first press of Like or Playlist on Spotify opens Spotify's consent
/// page in the default browser.
///
/// Endpoints as documented by Spotify after its February 2026 changes (checked 7 October 2026): saving and removing
/// go through `PUT`/`DELETE /me/library?uris=`, the state through `GET /me/library/contains?uris=` (the per-type
/// `/me/tracks` routes were removed), playlists through `GET /me/playlists` and adding through
/// `POST /playlists/{id}/items` (formerly `/tracks`).
enum NotchSpotify {
    /// The Client ID of the user's own app in Spotify's developer dashboard, with `redirectURI` registered there. The
    /// app loads it from `NotchSpotifyClientID` at launch; nil leaves Spotify out.
    static var clientID: String?
    static var configured: Bool { clientID != nil }

    /// The Keychain service for the Client ID and the tokens, after the bundle ID so Eclipse Beta keeps its own.
    static let keychainService = (Bundle.main.bundleIdentifier ?? "ro.andrei.NotchLab") + ".spotify"

    static let port: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:43821/callback"
    /// The library for the like; reading private and collaborative playlists and changing them for Playlist.
    static let scopes = ["user-library-read", "user-library-modify", "playlist-read-private", "playlist-read-collaborative",
                         "playlist-modify-public", "playlist-modify-private"]
    static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    static let api = URL(string: "https://api.spotify.com/v1/")!
    /// How long the browser may take to come back with the consent.
    static let authorizationTimeout: TimeInterval = 180

    /// Spotify's consent page for `pkce`.
    static func authorizeURL(_ pkce: NotchSpotifyPKCE) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID ?? ""),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        return components.url!
    }

    /// Whether `text` looks like a Client ID: 32 hexadecimal characters, as the dashboard shows it.
    static func validClientID(_ text: String) -> Bool {
        text.wholeMatch(of: #/[0-9a-fA-F]{32}/#) != nil
    }

    /// A track's URI as Spotify's AppleScript reports it, `spotify:track:` and a 22 character base62 ID. Episodes,
    /// ads and local files are not tracks the library or a playlist takes, and are nil.
    static func trackURI(_ text: String) -> String? {
        text.wholeMatch(of: #/spotify:track:[0-9A-Za-z]{22}/#) != nil ? text : nil
    }
}

/// One authorization's secrets: the code verifier, whose SHA-256 goes to Spotify as the challenge, and the state
/// that the callback must bring back. Both are drawn from the unreserved URL characters with the system's secure
/// random generator.
struct NotchSpotifyPKCE: Equatable {
    let verifier: String
    let state: String

    init(verifier: String = Self.random(64), state: String = Self.random(32)) {
        self.verifier = verifier
        self.state = state
    }

    var challenge: String { Self.challenge(for: verifier) }

    /// Base64url of the verifier's SHA-256, without padding (RFC 7636).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func random(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// What reached the loopback listener: Spotify's redirect with a code, with a refusal, with the wrong state, or
/// another request, such as the browser asking for a favicon. The listener waits on after the last two.
enum NotchSpotifyCallback: Equatable {
    case code(String)
    case denied
    case mismatch
    case ignored

    /// Parses the request's head. Only `GET /callback` counts, and only with the state this authorization sent.
    static func parse(request: String, state: String) -> NotchSpotifyCallback {
        let line = request.prefix { !$0.isNewline }.split(separator: " ")
        guard line.count == 3, line[0] == "GET", line[2].hasPrefix("HTTP/1."),
              let url = URLComponents(string: "http://127.0.0.1" + line[1]), url.path == "/callback" else { return .ignored }
        let items = url.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state, !state.isEmpty else { return .mismatch }
        if value("error") != nil { return .denied }
        guard let code = value("code"), !code.isEmpty else { return .denied }
        return .code(code)
    }
}

/// The Client ID in the login Keychain, on this Mac only. Not a secret, since PKCE needs none, but kept with the tokens.
enum NotchSpotifyClientID {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: NotchSpotify.keychainService,
                                              kSecAttrAccount as String: "clientID"]

    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let id = String(data: data, encoding: .utf8), NotchSpotify.validClientID(id) else { return nil }
        return id
    }

    /// Stores `id`, or deletes the stored one for nil, and makes it the current Client ID.
    static func save(_ id: String?) {
        SecItemDelete(base as CFDictionary)
        if let id {
            let attributes: [String: Any] = [kSecValueData as String: Data(id.utf8),
                                             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
        }
        NotchSpotify.clientID = id
    }
}

/// The tokens of a signed in Spotify account. Kept in the Keychain, never logged.
struct NotchSpotifyTokens: Codable, Equatable {
    var access: String
    var refresh: String
    var expires: Date

    /// Spotify's token reply. A refresh may come back without a refresh token, in which case the old one stays.
    static func decode(_ data: Data, now: Date, keeping previous: String? = nil) -> NotchSpotifyTokens? {
        struct Reply: Decodable {
            let access_token: String
            let token_type: String
            let expires_in: Double
            let refresh_token: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.access_token.isEmpty,
              reply.token_type.caseInsensitiveCompare("Bearer") == .orderedSame, reply.expires_in > 0,
              let refresh = reply.refresh_token ?? previous, !refresh.isEmpty else { return nil }
        return NotchSpotifyTokens(access: reply.access_token, refresh: refresh, expires: now.addingTimeInterval(reply.expires_in))
    }

    /// The access token is still good for a request, with a minute to spare.
    func fresh(at now: Date) -> Bool { now < expires.addingTimeInterval(-60) }
}

/// Where the tokens live: the Keychain in the app, memory in the checks.
struct NotchSpotifyTokenStore {
    let load: () -> NotchSpotifyTokens?
    let save: (NotchSpotifyTokens) -> Void
    let delete: () -> Void

    /// A generic password in the login keychain, readable after the first unlock and on this Mac only. The data
    /// protection keychain would need a signing team the ad hoc build does not have; the login keychain never syncs.
    /// Its access is tied to the app's designated requirement: an ad hoc update is a new app to the Keychain, which
    /// asks once before it lets the update read the tokens; a build signed with the same certificate reads them freely.
    static var keychain: NotchSpotifyTokenStore {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: NotchSpotify.keychainService,
                                   kSecAttrAccount as String: "tokens"]
        return NotchSpotifyTokenStore(load: {
            var query = base
            query[kSecReturnData as String] = true
            var item: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(NotchSpotifyTokens.self, from: data)
        }, save: { tokens in
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            let attributes: [String: Any] = [kSecValueData as String: data,
                                             kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
                SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
            }
        }, delete: {
            SecItemDelete(base as CFDictionary)
        })
    }

    static func memory(_ initial: NotchSpotifyTokens? = nil) -> NotchSpotifyTokenStore {
        final class Box { var tokens: NotchSpotifyTokens? }
        let box = Box()
        box.tokens = initial
        return NotchSpotifyTokenStore(load: { box.tokens }, save: { box.tokens = $0 }, delete: { box.tokens = nil })
    }
}

/// Why a Web API call gave no answer. `unauthorized` means there are no tokens now, so the next press signs in again.
enum NotchSpotifyFailure: Error, Equatable {
    case unauthorized
    case rateLimited
    case failed
}

/// A playlist the current track can go to.
struct NotchPlaylist: Hashable, Identifiable {
    let id: String
    let name: String
}

/// The signed in Spotify account and the few Web API calls Eclipse makes. Tokens load from the Keychain on first
/// use and refresh shortly before they expire, one refresh at a time. A 401 refreshes once and retries once; a
/// refresh Spotify rejects, as after the access was revoked, deletes the tokens. A 429 stops every call until its
/// Retry-After passed. Only HTTPS requests go out, and no token, code or verifier is ever logged.
@MainActor
final class NotchSpotifyAccount {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Runs the browser half of an authorization: opens the URL once the loopback listener is ready and returns what
    /// came back to it, or nil when it timed out or could not listen.
    typealias Consent = (NotchSpotifyPKCE) async -> NotchSpotifyCallback?

    private let store: NotchSpotifyTokenStore
    private let transport: Transport
    private let consent: Consent
    private let now: () -> Date
    private var tokens: NotchSpotifyTokens?
    private var loaded = false
    /// The refresh under way, with the serial that owns it, so a caller finishing late never clears a newer one.
    private var refreshing: (serial: Int, task: Task<Result<NotchSpotifyTokens, NotchSpotifyFailure>, Never>)?
    private var refreshSerial = 0
    private var authorizing: Task<Bool, Never>?
    /// Bumped by every sign out. Work started under an older generation, an authorization or a refresh still in flight
    /// when Forget was pressed, may not store its tokens or sign out the account that came after.
    private var generation = 0
    private var userID: String?
    /// No call goes out before this, after a 429.
    private(set) var retryAt: Date?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "spotify")

    private static let session = URLSession(configuration: .ephemeral)
    /// The one account Like and Playlist share.
    static let shared = NotchSpotifyAccount()

    init(store: NotchSpotifyTokenStore = .keychain,
         transport: @escaping Transport = { try await NotchSpotifyAccount.session.data(for: $0) },
         consent: Consent? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.transport = transport
        self.consent = consent ?? NotchSpotifyLoopback.consent
        self.now = now
    }

    /// Tokens are stored. Read from the Keychain the first time it is asked, which only a Spotify track does.
    var authorized: Bool {
        if !loaded { tokens = store.load(); loaded = true }
        return tokens != nil
    }

    /// Signs in when not signed in: opens Spotify's consent page in the browser and waits for its redirect. Callers
    /// arriving meanwhile wait for the same authorization. Returns whether tokens are stored now. Only a press calls
    /// it, never a read.
    func authorize() async -> Bool {
        if authorized { return true }
        if let authorizing { return await authorizing.value }
        let task = Task { await runAuthorization() }
        authorizing = task
        let result = await task.value
        if authorizing == task { authorizing = nil }
        return result
    }

    private func runAuthorization() async -> Bool {
        let started = generation
        guard let clientID = NotchSpotify.clientID else { return false }
        let pkce = NotchSpotifyPKCE()
        guard case .code(let code) = await consent(pkce) else {
            log.notice("Spotify authorization did not complete")
            return false
        }
        let reply = await post(NotchSpotify.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": NotchSpotify.redirectURI,
            "client_id": clientID, "code_verifier": pkce.verifier
        ])
        guard case .success(let data) = reply, let tokens = NotchSpotifyTokens.decode(data, now: now()) else {
            log.notice("Spotify token exchange failed")
            return false
        }
        return keep(tokens, from: started)
    }

    /// Whether the track is in Liked Songs.
    func saved(_ uri: String) async throws(NotchSpotifyFailure) -> Bool {
        let data = try await call("GET", "me/library/contains", query: ["uris": uri])
        guard let values = try? JSONDecoder().decode([Bool].self, from: data), let value = values.first else { throw .failed }
        return value
    }

    /// Saves the track to Liked Songs or removes it.
    func setSaved(_ uri: String, _ saved: Bool) async throws(NotchSpotifyFailure) {
        _ = try await call(saved ? "PUT" : "DELETE", "me/library", query: ["uris": uri])
    }

    /// The playlists the account owns or collaborates on, in Spotify's order, up to 200.
    func playlists() async throws(NotchSpotifyFailure) -> [NotchPlaylist] {
        struct Me: Decodable { let id: String }
        struct Page: Decodable {
            struct Item: Decodable {
                struct Owner: Decodable { let id: String? }
                let id: String?
                let name: String?
                let collaborative: Bool?
                let owner: Owner?
            }
            let items: [Item?]
            let next: String?
        }
        if userID == nil {
            let data = try await call("GET", "me")
            guard let me = try? JSONDecoder().decode(Me.self, from: data) else { throw .failed }
            userID = me.id
        }
        var result: [NotchPlaylist] = []
        for offset in stride(from: 0, to: 200, by: 50) {
            let data = try await call("GET", "me/playlists", query: ["limit": "50", "offset": String(offset)])
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw .failed }
            for case let item? in page.items {
                guard let id = item.id, let name = item.name, item.collaborative == true || item.owner?.id == userID else { continue }
                result.append(NotchPlaylist(id: id, name: name))
            }
            if page.next == nil { break }
        }
        return result
    }

    /// Appends the track to the playlist.
    func add(_ uri: String, to playlist: String) async throws(NotchSpotifyFailure) {
        guard playlist.wholeMatch(of: #/[0-9A-Za-z]+/#) != nil else { throw .failed }
        let body = try? JSONSerialization.data(withJSONObject: ["uris": [uri]])
        _ = try await call("POST", "playlists/\(playlist)/items", body: body)
    }

    /// One Web API call with a fresh access token, refreshed and retried once on a 401.
    private func call(_ method: String, _ path: String, query: [String: String] = [:],
                      body: Data? = nil) async throws(NotchSpotifyFailure) -> Data {
        for attempt in 0..<2 {
            let token = try await accessToken(refreshing: attempt > 0)
            var components = URLComponents(url: NotchSpotify.api.appending(path: path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
            var request = URLRequest(url: components.url!, timeoutInterval: 10)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (status, data) = try await send(request)
            switch status {
            case 200..<300: return data
            case 401 where attempt == 0: continue
            default:
                log.notice("Spotify \(method, privacy: .public) \(path, privacy: .public) answered \(status)")
                throw .failed
            }
        }
        throw .failed
    }

    /// The access token, refreshed when it is about to expire or `refreshing` asks for it after a 401.
    private func accessToken(refreshing force: Bool) async throws(NotchSpotifyFailure) -> String {
        guard authorized, let tokens else { throw .unauthorized }
        if !force, tokens.fresh(at: now()) { return tokens.access }
        if refreshing == nil {
            refreshSerial += 1
            refreshing = (refreshSerial, Task { await self.refresh(tokens) })
        }
        guard let (serial, task) = refreshing else { throw .failed }
        let result = await task.value
        if refreshing?.serial == serial { refreshing = nil }
        return try result.get().access
    }

    private func refresh(_ old: NotchSpotifyTokens) async -> Result<NotchSpotifyTokens, NotchSpotifyFailure> {
        let started = generation
        guard let clientID = NotchSpotify.clientID else { return .failure(.unauthorized) }
        let reply = await post(NotchSpotify.tokenEndpoint, form: [
            "grant_type": "refresh_token", "refresh_token": old.refresh, "client_id": clientID
        ])
        switch reply {
        case .success(let data):
            guard let tokens = NotchSpotifyTokens.decode(data, now: now(), keeping: old.refresh) else { return .failure(.failed) }
            return keep(tokens, from: started) ? .success(tokens) : .failure(.unauthorized)
        case .failure(.unauthorized):
            // Spotify refused the refresh token, as once the access was revoked: sign in again on the next press.
            guard generation == started else { return .failure(.unauthorized) }
            log.notice("Spotify refused the refresh; signing out")
            signOut()
            return .failure(.unauthorized)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Posts a form to the accounts service. A 400 or 401 there is a refused grant, reported as `unauthorized`.
    private func post(_ url: URL, form: [String: String]) async -> Result<Data, NotchSpotifyFailure> {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(form).utf8)
        do throws(NotchSpotifyFailure) {
            let (status, data) = try await send(request)
            switch status {
            case 200..<300: return .success(data)
            case 400, 401: return .failure(.unauthorized)
            default: return .failure(.failed)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Sends over HTTPS only, and turns a 429 into a pause of every call for its Retry-After, 5 s when it gives none.
    private func send(_ request: URLRequest) async throws(NotchSpotifyFailure) -> (Int, Data) {
        guard request.url?.scheme == "https" else { throw .failed }
        if let retryAt, now() < retryAt { throw .rateLimited }
        guard let (data, response) = try? await transport(request), let http = response as? HTTPURLResponse else { throw .failed }
        if http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
            retryAt = now().addingTimeInterval(min(max(wait, 1), 3600))
            log.notice("Spotify asked to wait \(Int(wait)) s")
            throw .rateLimited
        }
        return (http.statusCode, data)
    }

    /// Stores tokens from work started in `started`; false, storing nothing, when the account was signed out since.
    private func keep(_ tokens: NotchSpotifyTokens, from started: Int) -> Bool {
        guard generation == started else {
            log.notice("Dropped Spotify tokens that arrived after signing out")
            return false
        }
        self.tokens = tokens
        loaded = true
        store.save(tokens)
        return true
    }

    /// Forgets the account and cancels any sign in or refresh under way; the next press signs in again.
    func signOut() {
        generation += 1
        authorizing?.cancel()
        authorizing = nil
        refreshing?.task.cancel()
        refreshing = nil
        tokens = nil
        loaded = true
        userID = nil
        store.delete()
    }

    /// Percent-encodes a form, keeping only the unreserved characters.
    nonisolated static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// The short-lived HTTP listener Spotify redirects the browser to. It binds to 127.0.0.1:43821 only, opens the
/// consent page once it listens, answers the one `GET /callback` with this authorization's state with a small page
/// that says the tab can close, and stops. A callback with another state, as from an older sign in tab, gets a 400
/// and anything else a 404 while it waits on. It gives up after `NotchSpotify.authorizationTimeout`. A port
/// already in use ends the authorization quietly, with a line in the log.
final class NotchSpotifyLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ro.andrei.NotchLab.spotify-callback")
    private let state: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<NotchSpotifyCallback?, Never>?
    private static let log = Logger(subsystem: "ro.andrei.NotchLab", category: "spotify")

    private init(state: String) { self.state = state }

    /// The default `NotchSpotifyAccount.Consent`: listens, opens the consent page in the default browser and waits.
    @MainActor
    static func consent(_ pkce: NotchSpotifyPKCE) async -> NotchSpotifyCallback? {
        let url = NotchSpotify.authorizeURL(pkce)
        return await listen(state: pkce.state, timeout: NotchSpotify.authorizationTimeout) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    /// Listens until a callback arrives, `timeout` passes or the task is cancelled; calls `ready` once listening.
    static func listen(state: String, timeout: TimeInterval, ready: @escaping @Sendable () -> Void) async -> NotchSpotifyCallback? {
        let loopback = NotchSpotifyLoopback(state: state)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loopback.queue.async { loopback.start(continuation, timeout: timeout, ready: ready) }
            }
        } onCancel: {
            loopback.queue.async { loopback.finish(nil) }
        }
    }

    private func start(_ continuation: CheckedContinuation<NotchSpotifyCallback?, Never>, timeout: TimeInterval,
                       ready: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: NotchSpotify.port)!)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else { return finish(nil) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready()
            case .failed(let error):
                Self.log.notice("Spotify callback listener failed: \(error.localizedDescription, privacy: .public)")
                self?.finish(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
    }

    /// Reads one request head, up to 8 KB, and answers it.
    private func serve(_ connection: NWConnection, received: Data = Data()) {
        if received.isEmpty { connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.continuation != nil else { return connection.cancel() }
            let head = received + (data ?? Data())
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil || head.count >= 8192 || complete || error != nil else {
                return self.serve(connection, received: head)
            }
            let callback = NotchSpotifyCallback.parse(request: String(decoding: head, as: UTF8.self), state: self.state)
            let (status, message) = switch callback {
            case .code: ("200 OK", "Eclipse is connected to Spotify. You can close this tab.")
            case .denied: ("200 OK", "Eclipse was not connected to Spotify. You can close this tab.")
            case .mismatch: ("400 Bad Request", "This sign in link has expired. Press Like in Eclipse again.")
            case .ignored: ("404 Not Found", "")
            }
            let page = message.isEmpty ? "" : Self.page(message)
            let reply = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + page
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if callback != .ignored, callback != .mismatch { self.finish(callback) }
        }
    }

    private static func page(_ message: String) -> String {
        "<!doctype html><meta charset=\"utf-8\"><title>Eclipse</title><body style=\"margin:0;height:100vh;display:grid;"
            + "place-items:center;background:#000;color:#fff;font:15px -apple-system,sans-serif\">\(message)"
            + "<script>setTimeout(function(){window.close()},800)</script>"
    }

    private func finish(_ callback: NotchSpotifyCallback?) {
        listener?.cancel()
        listener = nil
        continuation?.resume(returning: callback)
        continuation = nil
    }
}
