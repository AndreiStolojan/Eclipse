import AppKit
import Foundation

/// A Spotify server that answers from a script of replies and records each request; every request must be HTTPS.
private final class FakeSpotify: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String, [String: String])] = []
    private(set) var requests: [URLRequest] = []

    func reply(_ status: Int, _ body: String = "", headers: [String: String] = [:]) {
        lock.withLock { replies.append((status, body, headers)) }
    }

    var paths: [String] { lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } } }
    func reset() { lock.withLock { requests = []; replies = [] } }

    var transport: NotchSpotifyAccount.Transport {
        { [self] request in
            precondition(request.url?.scheme == "https", "Only HTTPS leaves Eclipse")
            let (status, body, headers) = lock.withLock { () -> (Int, String, [String: String]) in
                requests.append(request)
                return replies.isEmpty ? (500, "", [:]) : replies.removeFirst()
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}

/// A Spotify server whose token requests wait until released, counting how many overlap; library reads answer from
/// a script of statuses.
private final class GatedSpotify: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var tokenRequests = 0
    var statuses: [Int] = []

    var pending: Int { lock.withLock { waiting.count } }

    func release() {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume()
    }

    var transport: NotchSpotifyAccount.Transport {
        { [self] request in
            if request.url?.path == "/api/token" {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        waiting.append(continuation)
                        tokenRequests += 1
                        inFlight += 1
                        maxInFlight = max(maxInFlight, inFlight)
                    }
                }
                lock.withLock { inFlight -= 1 }
                let body = #"{"access_token":"G","token_type":"Bearer","expires_in":3600,"refresh_token":"GR"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let status = lock.withLock { statuses.isEmpty ? 500 : statuses.removeFirst() }
            return (Data("[true]".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@main
struct NotchLikeChecks {
    @MainActor
    static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }

        // PKCE, against RFC 7636's example.
        check(NotchSpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
              "The challenge is the verifier's SHA-256 in base64url without padding")
        let pkce = NotchSpotifyPKCE()
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        check(pkce.verifier.count == 64 && pkce.state.count == 32 && pkce.verifier.unicodeScalars.allSatisfy(unreserved.contains)
              && NotchSpotifyPKCE().verifier != pkce.verifier, "Verifier and state are long, unreserved and fresh each time")

        // No Client ID ships: Spotify stays out until one is set, and only a dashboard-shaped one is taken.
        check(!NotchSpotify.configured && NotchLikeTarget(bundleIdentifier: "com.spotify.client", page: nil) == .unsupported,
              "Without a Client ID, Spotify has no like")
        check(NotchSpotify.validClientID("0123456789abcdef0123456789ABCDEF") && !NotchSpotify.validClientID("")
              && !NotchSpotify.validClientID("0123456789abcdef0123456789abcde") && !NotchSpotify.validClientID("<SPOTIFY_CLIENT_ID>")
              && !NotchSpotify.validClientID("0123456789abcdef0123456789abcdef "), "A Client ID is 32 hexadecimal characters")
        NotchSpotify.clientID = "0123456789abcdef0123456789abcdef"
        check(NotchLikeTarget(bundleIdentifier: "com.spotify.client", page: nil) == .spotify, "With a Client ID, Spotify has a like")

        // The consent page's address.
        let authorize = URLComponents(url: NotchSpotify.authorizeURL(pkce), resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (authorize.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        check(authorize.scheme == "https" && authorize.host == "accounts.spotify.com" && authorize.path == "/authorize"
              && query["response_type"] == "code" && query["redirect_uri"] == "http://127.0.0.1:43821/callback"
              && query["code_challenge_method"] == "S256" && query["code_challenge"] == pkce.challenge && query["state"] == pkce.state
              && query["client_id"] == NotchSpotify.clientID,
              "The authorize URL carries the code flow, the exact redirect, the S256 challenge and the state")
        check(query["scope"]?.split(separator: " ").count == NotchSpotify.scopes.count
              && NotchSpotify.authorizeURL(pkce).absoluteString.contains("scope=user-library-read%20"),
              "Scopes are space separated and encoded")

        // The loopback callback.
        func callback(_ line: String) -> NotchSpotifyCallback {
            NotchSpotifyCallback.parse(request: line + "\r\nHost: 127.0.0.1:43821\r\n\r\n", state: "S1")
        }
        check(callback("GET /callback?code=abc&state=S1 HTTP/1.1") == .code("abc"), "The redirect with the state gives its code")
        check(callback("GET /callback?code=abc&state=S2 HTTP/1.1") == .mismatch
              && callback("GET /callback?code=abc HTTP/1.1") == .mismatch
              && callback("GET /callback?error=access_denied&state=S2 HTTP/1.1") == .mismatch,
              "A wrong or missing state is refused, refusal or not")
        check(callback("GET /callback?error=access_denied&state=S1 HTTP/1.1") == .denied
              && callback("GET /callback?state=S1&code= HTTP/1.1") == .denied, "A refusal or an empty code is denied")
        check(callback("GET /favicon.ico HTTP/1.1") == .ignored && callback("POST /callback?code=a&state=S1 HTTP/1.1") == .ignored
              && callback("GET /callback/x?code=a&state=S1 HTTP/1.1") == .ignored && callback("garbage") == .ignored,
              "Only GET /callback counts")

        // Tokens.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = NotchSpotifyTokens.decode(Data(#"{"access_token":"A1","token_type":"Bearer","expires_in":3600,"refresh_token":"R1","scope":"x"}"#.utf8), now: now)
        check(first == NotchSpotifyTokens(access: "A1", refresh: "R1", expires: now + 3600), "The token reply decodes with its expiry")
        let refreshed = NotchSpotifyTokens.decode(Data(#"{"access_token":"A2","token_type":"bearer","expires_in":3600}"#.utf8), now: now, keeping: "R1")
        check(refreshed?.refresh == "R1" && refreshed?.access == "A2", "A refresh without a new refresh token keeps the old one")
        check(NotchSpotifyTokens.decode(Data(#"{"access_token":"A2","token_type":"Bearer","expires_in":3600}"#.utf8), now: now) == nil
              && NotchSpotifyTokens.decode(Data(#"{"access_token":"A","token_type":"MAC","expires_in":3600,"refresh_token":"R"}"#.utf8), now: now) == nil
              && NotchSpotifyTokens.decode(Data(#"{"access_token":"A","token_type":"Bearer","expires_in":0,"refresh_token":"R"}"#.utf8), now: now) == nil
              && NotchSpotifyTokens.decode(Data("<html>".utf8), now: now) == nil,
              "Replies without a refresh token, of another type, already expired or not JSON are refused")
        check(first!.fresh(at: now + 3539) && !first!.fresh(at: now + 3541), "A token is refreshed a minute before it expires")
        check(NotchSpotifyAccount.form(["b": "a b&c=d", "a": "é~"]) == "a=%C3%A9~&b=a%20b%26c%3Dd", "Form values are fully encoded")

        // Spotify's current track.
        let id = "spotify:track:7KGHenqXZofXNm5MKDbT3J"
        func track(_ output: String, status: Int32 = 0) -> NotchSpotifyTrack {
            NotchSpotifyTrack.parse(status: status, output: output, title: "Whisper My Name", artist: "Drake, Guest")
        }
        check(track("\(id)\u{1F}Whisper My Name\u{1F}Drake\n") == .track(id), "The track's URI, its artist the first of several")
        check(track("\(id)\u{1F}Another\u{1F}Drake") == .changed && track("\(id)\u{1F}Whisper My Name\u{1F}Other") == .changed,
              "Another title or artist is another track")
        check(track("spotify:episode:7KGHenqXZofXNm5MKDbT3J\u{1F}Whisper My Name\u{1F}Drake") == .other
              && track("spotify:local:x:y:z:1\u{1F}Whisper My Name\u{1F}Drake") == .other
              && track("spotify:track:short\u{1F}Whisper My Name\u{1F}Drake") == .other, "Episodes, local files and odd IDs are no tracks")
        check(track("missing") == .missing && track("", status: Int32(procNotFound)) == .missing && track("", status: 1) == .failed,
              "Stopped, quit and failed")

        // The Spotify like's flow, against a scripted server.
        let server = FakeSpotify()
        var clock = now
        var consents: [NotchSpotifyPKCE] = []
        var consentReply: NotchSpotifyCallback? = nil
        let store = NotchSpotifyTokenStore.memory()
        let account = NotchSpotifyAccount(store: store, transport: server.transport, consent: { pkce in
            consents.append(pkce)
            return consentReply
        }, now: { clock })
        var tracks: [NotchSpotifyTrack] = []
        var reply = NotchLikeReply.failed
        func like(toggle: Bool, wanted: Bool = true, playing: [NotchSpotifyTrack] = [.track(id)]) async -> NotchLikeReply {
            tracks = playing
            return await NotchSpotifyLike.run(toggle: toggle, wanted: wanted, account: account) {
                tracks.count > 1 ? tracks.removeFirst() : tracks[0]
            }
        }
        reply = await like(toggle: false)
        check(reply == .unauthorized && consents.isEmpty && server.requests.isEmpty,
              "A read without tokens neither signs in nor goes out")
        consentReply = nil
        reply = await like(toggle: true)
        check(reply == .unauthorized && consents.count == 1 && server.requests.isEmpty,
              "A press whose sign in times out or cannot listen leaves the like alone")
        consentReply = .denied
        reply = await like(toggle: true)
        check(reply == .unauthorized && consents.count == 2 && store.load() == nil, "A refused sign in stores nothing")
        consentReply = .code("C1")
        server.reply(200, #"{"access_token":"A1","token_type":"Bearer","expires_in":3600,"refresh_token":"R1"}"#)
        reply = await like(toggle: true, playing: [.track(id), .track("spotify:track:0000000000000000000000")])
        check(reply == .changed
              && server.paths == ["POST /api/token"] && store.load()?.access == "A1",
              "After signing in, a track that changed meanwhile is not liked")
        let exchange = String(decoding: server.requests[0].httpBody ?? Data(), as: UTF8.self)
        check(exchange.contains("grant_type=authorization_code") && exchange.contains("code=C1")
              && exchange.contains("code_verifier=\(consents[2].verifier)") && exchange.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A43821%2Fcallback")
              && !exchange.contains("client_secret"), "The code is exchanged with the verifier and the redirect, without a secret")
        account.signOut()
        server.reset()
        server.reply(200, #"{"access_token":"A1","token_type":"Bearer","expires_in":3600,"refresh_token":"R1"}"#)
        server.reply(200)
        reply = await like(toggle: true)
        check(reply == .liked(true) && server.paths == ["POST /api/token", "PUT /v1/me/library"]
              && server.requests[1].url?.query == "uris=spotify:track:7KGHenqXZofXNm5MKDbT3J"
              && server.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer A1",
              "The first press signs in once and then likes the same track")
        server.reset()
        server.reply(200, "[true]")
        reply = await like(toggle: false)
        check(reply == .liked(true) && server.paths == ["GET /v1/me/library/contains"] && consents.count == 4,
              "Signed in, a read asks the library without signing in again")
        server.reset()
        server.reply(200)
        reply = await like(toggle: true, wanted: false)
        check(reply == .liked(false) && server.paths == ["DELETE /v1/me/library"],
              "Unliking removes the track")
        server.reset()
        clock = now + 3590
        server.reply(200, #"{"access_token":"A2","token_type":"Bearer","expires_in":3600}"#)
        server.reply(200, "[false]")
        let refreshBody = { String(decoding: server.requests[0].httpBody ?? Data(), as: UTF8.self) }
        reply = await like(toggle: false)
        check(reply == .liked(false) && server.paths == ["POST /api/token", "GET /v1/me/library/contains"]
              && refreshBody().contains("grant_type=refresh_token") && refreshBody().contains("refresh_token=R1")
              && store.load()?.refresh == "R1", "An expiring token refreshes first and keeps its refresh token")
        server.reset()
        server.reply(401)
        server.reply(200, #"{"access_token":"A3","token_type":"Bearer","expires_in":3600}"#)
        server.reply(200, "[true]")
        reply = await like(toggle: false)
        check(reply == .liked(true)
              && server.paths == ["GET /v1/me/library/contains", "POST /api/token", "GET /v1/me/library/contains"]
              && server.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer A3", "A 401 refreshes and retries once")
        server.reset()
        server.reply(401)
        server.reply(200, #"{"access_token":"A4","token_type":"Bearer","expires_in":3600}"#)
        server.reply(401)
        reply = await like(toggle: false)
        check(reply == .failed && server.requests.count == 3 && store.load() != nil,
              "A second 401 gives up without looping or signing out")
        server.reset()
        server.reply(429, headers: ["Retry-After": "30"])
        reply = await like(toggle: true)
        check(reply == .failed && account.retryAt == clock + 30, "A 429 fails the press and records its Retry-After")
        server.reset()
        reply = await like(toggle: false)
        check(reply == .failed && server.requests.isEmpty, "Nothing goes out before Retry-After passed")
        clock += 31
        server.reply(200, "[true]")
        reply = await like(toggle: false)
        check(reply == .liked(true) && server.requests.count == 1, "Calls resume once it passed")
        // A Retry-After that is not a finite number of seconds, or out of range, never traps and is held to 1 s..1 h.
        for (header, wait) in [("inf", 5.0), ("nan", 5), ("-inf", 5), ("1e300", 3600), ("0", 1)] {
            let limited = FakeSpotify()
            limited.reply(429, headers: ["Retry-After": header])
            let limitedAccount = NotchSpotifyAccount(store: .memory(NotchSpotifyTokens(access: "L", refresh: "R", expires: now + 3600)),
                                                     transport: limited.transport, consent: { _ in nil }, now: { now })
            let failure: NotchSpotifyFailure? = await {
                do throws(NotchSpotifyFailure) { _ = try await limitedAccount.saved(id); return nil } catch { return error }
            }()
            check(failure == .rateLimited && limitedAccount.retryAt == now + wait, "A Retry-After of \(header) waits \(Int(wait)) s")
        }
        server.reset()
        server.reply(401)
        server.reply(400, #"{"error":"invalid_grant"}"#)
        reply = await like(toggle: false)
        check(reply == .unauthorized && store.load() == nil && !account.authorized,
              "A refused refresh deletes the tokens, so the next press signs in again")
        reply = await like(toggle: true, playing: [.other])
        check(reply == .missing && consents.count == 4, "An episode or an ad is not liked or signed in for")
        server.reset()
        consentReply = .code("C1")
        server.reply(200, #"{"access_token":"V1","token_type":"Bearer","expires_in":3600,"refresh_token":"R1"}"#)
        tracks = [.track(id)]
        reply = await NotchSpotifyLike.run(toggle: true, wanted: true, account: account, valid: { false }) { tracks[0] }
        check(reply == .changed && server.paths == ["POST /api/token"],
              "A like whose button left view during the sign in is not saved once it completes")
        account.signOut()
        server.reset()
        server.reply(200, #"{"access_token":"V2","token_type":"Bearer","expires_in":3600,"refresh_token":"R1"}"#)
        var validity = [true, false]
        reply = await NotchSpotifyLike.run(toggle: true, wanted: true, account: account, valid: { validity.removeFirst() }) { tracks[0] }
        check(reply == .changed && server.paths == ["POST /api/token"] && validity.isEmpty,
              "Validity is checked again right before saving")
        account.signOut()

        // Signing in once for several presses, and the playlists.
        server.reset()
        consentReply = .code("C1")
        server.reply(200, #"{"access_token":"B1","token_type":"Bearer","expires_in":3600,"refresh_token":"R2"}"#)
        let consented = consents.count
        async let one = account.authorize()
        async let two = account.authorize()
        let both = await (one, two)
        check(both == (true, true) && consents.count == consented + 1 && server.paths == ["POST /api/token"], "Presses during a sign in share it")
        server.reset()
        server.reply(200, #"{"id":"me"}"#)
        server.reply(200, #"{"items":[{"id":"P1","name":"Mine","collaborative":false,"owner":{"id":"me"}},{"id":"P2","name":"Followed","collaborative":false,"owner":{"id":"them"}},null],"next":"https://api.spotify.com/v1/me/playlists?offset=50"}"#)
        server.reply(200, #"{"items":[{"id":"P3","name":"Shared","collaborative":true,"owner":{"id":"them"}}],"next":null}"#)
        let lists = try? await account.playlists()
        check(lists == [NotchPlaylist(id: "P1", name: "Mine"), NotchPlaylist(id: "P3", name: "Shared")]
              && server.paths == ["GET /v1/me", "GET /v1/me/playlists", "GET /v1/me/playlists"]
              && server.requests[2].url?.query == "limit=50&offset=50", "Only owned or collaborative playlists, page by page")
        server.reset()
        server.reply(201, #"{"snapshot_id":"x"}"#)
        let added: Bool = await { do { try await account.add(id, to: "P1"); return true } catch { return false } }()
        let body = server.requests.first.flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] }
        check(added && server.paths == ["POST /v1/playlists/P1/items"] && body == ["uris": [id]], "Adding posts the track's URI to the playlist's items")
        server.reset()
        let odd: Bool = await { do { try await account.add(id, to: "../me"); return true } catch { return false } }()
        check(!odd && server.requests.isEmpty, "A playlist ID that is not one never reaches a URL")

        // Refreshes never overlap: callers during one share it, and forced refreshes after 401s share the next.
        let gated = GatedSpotify()
        let shared = NotchSpotifyAccount(store: .memory(NotchSpotifyTokens(access: "OLD", refresh: "R", expires: now)),
                                         transport: gated.transport, consent: { _ in nil }, now: { now + 10 })
        @MainActor func waitForRefresh(_ count: Int) async {
            for _ in 0..<400 where gated.pending < 1 || gated.tokenRequests < count { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        gated.statuses = [200, 200, 200]
        let expired = (0..<3).map { _ in Task { @MainActor in try? await shared.saved(id) } }
        await waitForRefresh(1)
        check(gated.tokenRequests == 1, "Calls with an expired token wait for one refresh")
        gated.release()
        var answers: [Bool?] = []
        for call in expired { answers.append(await call.value) }
        check(answers == [true, true, true] && gated.tokenRequests == 1 && gated.maxInFlight == 1, "and all go on with it")
        gated.statuses = [401, 401, 200, 200]
        let rejected = (0..<2).map { _ in Task { @MainActor in try? await shared.saved(id) } }
        await waitForRefresh(2)
        check(gated.tokenRequests == 2, "Two 401s during one refresh share it")
        gated.release()
        answers = []
        for call in rejected { answers.append(await call.value) }
        check(answers == [true, true] && gated.tokenRequests == 2 && gated.maxInFlight == 1, "No refresh ever overlaps another")

        // Forget wins over work still in flight: a sign in or a refresh that finishes after it stores nothing.
        let racing = GatedSpotify()
        @MainActor func waitForTokenRequest() async {
            for _ in 0..<400 where racing.pending < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let forgetStore = NotchSpotifyTokenStore.memory()
        let forgetting = NotchSpotifyAccount(store: forgetStore, transport: racing.transport, consent: { _ in .code("C") }, now: { now })
        let signingIn = Task { @MainActor in await forgetting.authorize() }
        await waitForTokenRequest()
        forgetting.signOut()
        racing.release()
        let signedIn = await signingIn.value
        check(racing.tokenRequests == 1 && !signedIn && !forgetting.authorized && forgetStore.load() == nil,
              "A sign in that finishes after Forget stores nothing")
        let refreshStore = NotchSpotifyTokenStore.memory(NotchSpotifyTokens(access: "OLD", refresh: "R", expires: now))
        let lateRefresh = NotchSpotifyAccount(store: refreshStore, transport: racing.transport, consent: { _ in nil }, now: { now + 10 })
        racing.statuses = [200]
        let reading = Task { @MainActor in try? await lateRefresh.saved(id) }
        await waitForTokenRequest()
        lateRefresh.signOut()
        racing.release()
        let read = await reading.value
        check(racing.tokenRequests == 2 && read == nil && !lateRefresh.authorized && refreshStore.load() == nil,
              "A refresh that finishes after Forget stores nothing and makes no call")

        // The loopback listener, over 127.0.0.1: a favicon gets a 404 while it waits, the callback a page, a second
        // listener on the busy port gives up at once, and an unanswered one times out.
        @Sendable func get(_ path: String) async -> (Int, String) {
            guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:43821" + path)!)
            else { return (0, "") }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        final class Box: @unchecked Sendable { var replies: [(Int, String)] = []; var busy: NotchSpotifyCallback?? }
        let box = Box()
        let completed = DispatchGroup()
        completed.enter()
        let heard = await NotchSpotifyLoopback.listen(state: "S1", timeout: 10) {
            Task.detached {
                defer { completed.leave() }
                box.busy = .some(await NotchSpotifyLoopback.listen(state: "S2", timeout: 10) {})
                box.replies.append(await get("/favicon.ico"))
                box.replies.append(await get("/callback?code=OLD&state=S0"))
                box.replies.append(await get("/callback?code=C9&state=S1"))
            }
        }
        check(heard == .code("C9"), "The listener receives the valid callback")
        // The listener resumes before the client necessarily finishes receiving its reply. Join that client before
        // reading its results; a fixed sleep neither synchronizes Box nor proves the last response has arrived.
        await Task.detached { completed.wait() }.value
        check(heard == .code("C9") && box.replies.map(\.0) == [404, 400, 200]
              && box.replies.last?.1.contains("You can close this tab") == true,
              "The listener refuses a wrong state with a 400, waits on, answers the valid callback and stops")
        check(box.busy == .some(nil), "A port already in use ends the sign in quietly")
        let silent = await NotchSpotifyLoopback.listen(state: "S1", timeout: 0.3) {}
        let (closed, _) = await get("/callback?code=C9&state=S1")
        check(silent == nil && closed == 0, "Unanswered, the listener times out and the port closes")

        // The like's ledger with Spotify's sign in.
        let request = NotchLikeRequest(target: .music, track: "A", title: "A", artist: "X")
        let other = NotchLikeRequest(target: .music, track: "B", title: "B", artist: "X")
        var ledger = NotchLikeLedger()
        _ = ledger.show(request)
        check(ledger.beginToggle(optimistic: false) == request && ledger.liked == nil && ledger.wanted,
              "A press that must sign in first does not flip the heart, and asks for a like")
        check(ledger.mayAct(ledger.toggleSerial) && ledger.finishToggle(.unauthorized, serial: ledger.toggleSerial).landed
              && ledger.liked == nil, "A sign in that did not complete leaves the heart as it was")
        _ = ledger.finishRead(.liked(true), generation: ledger.show(request)!)
        check(ledger.beginToggle() == request && ledger.liked == false && !ledger.wanted && !ledger.pending,
              "Signed in, a press flips at once")
        _ = ledger.finishToggle(.liked(false), serial: ledger.toggleSerial)
        _ = ledger.beginToggle(optimistic: false)
        let given = ledger.toggleSerial
        _ = ledger.show(nil)
        check(!ledger.pending && ledger.toggling == nil && !ledger.mayAct(given), "A pending like is given up once its button leaves view")
        check(ledger.show(request) != nil && !ledger.mayAct(given), "and stays given up when it comes back, which reads at once")
        check(!ledger.finishToggle(.liked(true), serial: given).landed && ledger.liked == false,
              "The given up like's reply lands nothing")
        _ = ledger.beginToggle(optimistic: false)
        let replaced = ledger.toggleSerial
        check(ledger.show(other) != nil && !ledger.mayAct(replaced), "Another track in view gives it up too")
        _ = ledger.show(request)
        _ = ledger.beginToggle()
        _ = ledger.show(nil)
        check(ledger.toggling == request, "A like already sent is not given up")

        // A YouTube tab out of reach is checked again on a press of the dimmed heart or when its browser comes forward.
        let tab = NotchLikeRequest(target: .zen, track: "V", title: "V", artist: "")
        var reach = NotchLikeLedger()
        _ = reach.show(tab)
        check(reach.retry(unreachable: tab) != nil && reach.retry(unreachable: tab, activated: "app.zen-browser.zen") != nil,
              "A press of the dimmed heart or Zen coming forward reads the tab again")
        check(reach.retry(unreachable: tab, activated: NotchWebSites.safari) == nil && reach.retry(unreachable: nil) == nil
              && reach.retry(unreachable: request) == nil, "Another app, a reachable tab or another track reads nothing")
        _ = reach.show(nil)
        check(reach.retry(unreachable: tab) == nil, "Out of view, nothing is read")

        // The Playlist button's ledger.
        var playlists = NotchPlaylistLedger()
        check(playlists.beginList() == nil, "Out of view, a press lists nothing")
        playlists.show(request)
        check(playlists.beginList() == request && playlists.beginList() == nil, "One list at a time")
        playlists.show(other)
        check(!playlists.finishList(for: request) && playlists.busy == nil, "A list for a track no longer shown opens no menu")
        check(playlists.beginList() == other && playlists.finishList(for: other), "The track on screen gets its menu")
        _ = playlists.beginList()
        playlists.show(nil)
        playlists.show(other)
        check(!playlists.finishList(for: other) && playlists.busy == nil, "A list whose button left view meanwhile opens no menu")
        _ = playlists.beginList()
        check(playlists.mayList(other) && !playlists.mayList(request), "A list in view may read for its own track")
        playlists.show(nil)
        playlists.show(other)
        check(!playlists.mayList(other), "Once its button left view, a list does not read after signing in, even back in view")
        _ = playlists.finishList(for: other)
        check(playlists.beginAdd(for: other) && !playlists.beginAdd(for: other), "One add at a time")
        let serial = playlists.finishAdd(.added, for: other)
        check(serial != nil && playlists.outcome?.added == true && playlists.outcome?.request == other, "The add shows its checkmark")
        check(playlists.beginAdd(for: other) && playlists.finishAdd(.changed, for: other) == nil && playlists.outcome?.serial == serial,
              "A changed track shows nothing new")
        _ = playlists.beginAdd(for: other)
        playlists.show(request)
        check(playlists.finishAdd(.failed, for: other) == nil, "An outcome for a track no longer shown does not show")
        playlists.clearOutcome(serial! + 1)
        check(playlists.outcome != nil, "Only its own timer clears an outcome")
        playlists.clearOutcome(serial!)
        check(playlists.outcome == nil, "and it does")

        // The menu's order.
        let menu = NotchPlaylistMenu(request: request, playlists: [NotchPlaylist(id: "1", name: "Song 10"), NotchPlaylist(id: "2", name: "song 2"),
                                                                   NotchPlaylist(id: "3", name: "Alpha"), NotchPlaylist(id: "4", name: "Zed"),
                                                                   NotchPlaylist(id: "5", name: "Beta")],
                                     recent: ["4", "gone", "1", "5", "3"])
        check(menu.recent.map(\.id) == ["4", "1", "5"] && menu.rest.map(\.name) == ["Alpha", "song 2"],
              "Recently used first, up to three that still exist, then the rest sorted as Finder sorts")

        // Apple Music's playlists.
        let listed = NotchMusicPlaylists.parse("1FB1E6220DDC1C7D\u{1F}Road\ttrip\nmix\u{1E}bad\u{1F}x\u{1E}8EF2E536DCE72B85\u{1F}\u{1E}\n")
        check(listed == [NotchPlaylist(id: "1FB1E6220DDC1C7D", name: "Road\ttrip\nmix"), NotchPlaylist(id: "8EF2E536DCE72B85", name: "")],
              "Playlist names keep tabs and line breaks; records without a persistent ID are dropped")
        let road = NotchPlaylist(id: "1FB1E6220DDC1C7D", name: "\" & quit")
        check(NotchMusicPlaylists.addArguments(playlist: road, request: NotchLikeRequest(target: .music, track: "t", title: "Song \"x\"", artist: "A"))
              == ["1FB1E6220DDC1C7D", "Song \"x\"", "A"] && !NotchMusicPlaylists.addScript.contains("quit"),
              "The add takes the persistent ID, the title and the artist as arguments, never as source")
        let add = NotchMusicPlaylists.addScript
        check(!add.contains("whose name") && add.contains("whose persistent ID is trackID")
              && add.range(of: "if copies is not {} then return \"failed\"")!.lowerBound < add.range(of: "to library playlist 1")!.lowerBound
              && add.contains("set copied to duplicate t to library playlist 1"),
              "The add finds the library copy by persistent ID, never by name, and adds to the library only without one")
        for (name, source) in [("list", NotchMusicPlaylists.listScript), ("add", NotchMusicPlaylists.addScript)] {
            var error: NSDictionary?
            check(NSAppleScript(source: source)?.compileAndReturnError(&error) == true, "The Music \(name) script compiles")
        }
        check(NotchPlaylistResult(musicOutput: "added\n", status: 0) == .added && NotchPlaylistResult(musicOutput: "changed", status: 0) == .changed
              && NotchPlaylistResult(musicOutput: "missing", status: 0) == .failed && NotchPlaylistResult(musicOutput: "", status: 1) == .failed,
              "Music's add replies parse")

        // YouTube's like through Accessibility, from the tree WebKit built for YouTube's markup on 7 October 2026.
        let likeToggle = NotchAXToggle(description: "like this video along with 12,345 other people",
                                       classes: ["yt-spec-button-shape-next", "yt-spec-button-shape-next--tonal",
                                                 "yt-spec-button-shape-next--segmented-start"], pressed: false,
                                       parentClasses: ["ytSegmentedLikeDislikeButtonViewModelSegmentedButtonsWrapper"])
        let dislike = NotchAXToggle(description: "Dislike this video", classes: ["yt-spec-button-shape-next",
                                                                                 "yt-spec-button-shape-next--segmented-end"], pressed: false,
                                    parentClasses: ["ytSegmentedLikeDislikeButtonViewModelSegmentedButtonsWrapper"])
        let musicLike = NotchAXToggle(description: "Like", pressed: true, parentIdentifier: "button-shape-like")
        check(NotchYouTubeAX.likeButton(in: [dislike, likeToggle, musicLike], music: false) == 1, "The watch page's like is the pair's start")
        var romanian = likeToggle
        romanian.classes = []
        romanian.parentClasses = []
        romanian.description = "Apreciază acest videoclip împreună cu alți 12.345 de utilizatori"
        check(NotchYouTubeAX.likeButton(in: [dislike, romanian], music: false) == 1, "Without the classes, the Romanian label finds it")
        var unpaired = likeToggle
        unpaired.parentClasses = []
        check(NotchYouTubeAX.likeButton(in: [unpaired, unpaired], music: false) == nil, "Two candidates of the same rank press nothing")
        var disabled = likeToggle
        disabled.enabled = false
        check(NotchYouTubeAX.likeButton(in: [disabled], music: false) == nil
              && NotchYouTubeAX.likeButton(in: [NotchAXToggle(description: "Subscribe", pressed: false)], music: false) == nil,
              "A disabled like or an unrelated toggle is never pressed")
        var musicLiked = musicLike
        musicLiked.pressed = false
        check(NotchYouTubeAX.likeButton(in: [likeToggle, musicLike, musicLike], music: true) == 1
              && NotchYouTubeAX.likeButton(in: [musicLike, musicLiked], music: true) == nil,
              "YouTube Music's like is in #button-shape-like; copies must agree")
        let watch = URL(string: "https://www.youtube.com/watch?v=abc")!
        check(NotchYouTubeAX.match([(watch.absoluteString, "(3) Video A - YouTube")], page: watch, title: "Video A") == .found(0),
              "The tab in front at the address and naming the video is the one")
        check(NotchYouTubeAX.match([("https://www.youtube.com/watch?v=xyz", "Video A - YouTube")], page: watch, title: "Video A") == .unreachable
              && NotchYouTubeAX.match([(watch.absoluteString, "Video A - YouTube"), (watch.absoluteString, "Video A - YouTube")],
                                      page: watch, title: "Video A") == .unreachable,
              "A background tab, another Space or two matching tabs are out of reach")
        check(NotchYouTubeAX.match([(watch.absoluteString, "Video A (Live) - YouTube")], page: watch, title: "Video A") == .changed
              && NotchYouTubeAX.match([(watch.absoluteString, "Video A - YouTube")], page: watch, title: "") == .changed,
              "Another or an unnamed video in that tab is left alone")
        check(NotchYouTubeAX.supports(watch) && NotchYouTubeAX.supports(URL(string: "https://music.youtube.com/watch?v=abc")!)
              && !NotchYouTubeAX.supports(URL(string: "https://www.youtube.com/shorts/abc")!)
              && !NotchYouTubeAX.supports(URL(string: "https://www.netflix.com/watch/1")!),
              "Only watch pages, where one like belongs to one video")
        check(NotchLikeReply(status: 0, output: "true", error: "") != .unreachable, "Accessibility's refusal is its own reply")

        // Zen, from Gecko's tree on 7 October 2026: the selected tab's web area with its address and the page title
        // as description, toggles without classes, and Romanian labels.
        check(NotchLikeTarget(bundleIdentifier: "app.zen-browser.zen", page: nil) == .zen && NotchLikeTarget.zen.isYouTube,
              "Zen media likes through Accessibility")
        let home = ("https://www.youtube.com/", "YouTube"), other1 = ("https://example.com/", "Video A")
        check(NotchYouTubeAX.match([other1, (watch.absoluteString, "(2) Video A - YouTube")], page: nil, title: "Video A") == .found(1),
              "In Zen, the one tab in front on a YouTube video naming the track is the one")
        check(NotchYouTubeAX.match([home], page: nil, title: "Video A") == .unreachable
              && NotchYouTubeAX.match([("https://www.youtube.com/shorts/abc", "Video A - YouTube")], page: nil, title: "Video A") == .unreachable
              && NotchYouTubeAX.match([(watch.absoluteString, "Video B - YouTube")], page: nil, title: "Video A") == .unreachable
              && NotchYouTubeAX.match([(watch.absoluteString, "Video A - YouTube"), ("https://www.youtube.com/watch?v=xyz", "Video A - YouTube")],
                                      page: nil, title: "Video A") == .unreachable,
              "The home page, Shorts, another video in front or two videos side by side are out of reach")
        let gecko = { (label: String, pressed: Bool) in NotchAXToggle(description: label, pressed: pressed) }
        check(NotchYouTubeAX.likeButton(in: [gecko("Nu apreciez acest videoclip", false), gecko("Apreciază acest comentariu", false),
                                             gecko("Apreciază acest videoclip împreună cu alți 1.234 de utilizatori", true)], music: false) == 2
              && NotchYouTubeAX.likeButton(in: [gecko("Dislike this video", false), gecko("like this video along with 9 other people", false)],
                                           music: false) == 1,
              "Without classes, the like is found by its label, not the dislike or a comment's like")
        // Right before the press, the like must be the video's, not a comment's.
        let commentLike = gecko("Like this comment along with 3 other people", false)
        let metadata: [(identifier: String?, classes: [String])] = [(nil, ["ytSegmentedLikeDislikeButtonViewModelSegmentedButtonsWrapper"]),
                                                                       ("actions", ["style-scope", "ytd-watch-metadata"])]
        check(NotchYouTubeAX.inActionBar(1, of: [dislike, likeToggle, commentLike], ancestry: metadata, music: false)
              && NotchYouTubeAX.inActionBar(0, of: [gecko("like this video", false), commentLike], ancestry: [], music: false),
              "The like among the video's actions, or the first like in document order, is the video's")
        check(!NotchYouTubeAX.inActionBar(1, of: [commentLike, gecko("like this video", false)], ancestry: [], music: false)
              && !NotchYouTubeAX.inActionBar(0, of: [likeToggle], ancestry: [("comments", [])] + metadata, music: false)
              && !NotchYouTubeAX.inActionBar(0, of: [musicLike], ancestry: [(nil, ["ytd-comment-engagement-bar"])], music: true),
              "A like after another, or anywhere in the comments, is never pressed")
        var later = gecko("like this video", false)
        later.search = 1
        check(NotchYouTubeAX.inActionBar(1, of: [commentLike, later], ancestry: [], music: false),
              "Document order holds within each of Gecko's searches")
        check((NotchYouTubeAX.videoLabels + NotchYouTubeAX.musicLabels).allSatisfy { label in
            NotchYouTubeAX.searchWords.contains { label.contains($0) }
        }, "Gecko's name search covers every label the like is told by")
        var timedOut = NotchAXSession(stop: NotchStopFlag())
        var absent = NotchAXSession(stop: NotchStopFlag())
        check(!timedOut.accept(.cannotComplete) && timedOut.exhausted
              && !absent.accept(.noValue) && !absent.accept(.attributeUnsupported) && !absent.exhausted
              && absent.accept(.success),
              "A request that times out spends the like's session; one that finds no value does not")
        let stopped = NotchStopFlag()
        stopped.set()
        var cancelled = NotchAXSession(stop: stopped)
        check(!cancelled.allow(AXUIElementCreateSystemWide()) && cancelled.exhausted,
              "A cancelled like read sends no further request")
        func embedded(_ error: AXError) -> AnyObject {
            var error = error
            return AXValueCreate(.axError, &error)!
        }
        var batch = NotchAXSession(stop: NotchStopFlag())
        let values = NotchBrowserLike.decode(["AXToggle" as NSString, embedded(.noValue)], &batch)
        check(values[0] as? String == "AXToggle" && values[1] == nil && !batch.exhausted,
              "A batch read keeps its values and reads an embedded absent value as nil")
        _ = NotchBrowserLike.decode([embedded(.cannotComplete)], &batch)
        check(batch.exhausted, "An embedded failure in a batch read spends the like's session")

        print("\(checks) like checks passed")
    }
}
