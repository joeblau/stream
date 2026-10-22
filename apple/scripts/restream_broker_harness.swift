import Foundation
import StreamCore

@MainActor protocol ProviderRestreamBoundary: AnyObject, Sendable {
    var hasProviderAuthorization: Bool { get }
    var providerAuthorizationGeneration: UUID? { get }
    var providerGrantedScopes: Set<String>? { get }
    func signOut()
    func authorizedProviderRequest(_ request: URLRequest) async throws -> Data
}
private actor BrokerFixture {
    var calls: [URLRequest] = []
    var held: String?, entered = false, gate: CheckedContinuation<Void, Never>?
    var badSecret = false
    let id = String(repeating: "i", count: 43), credential = String(repeating: "c", count: 43)
    func hold(_ suffix: String) { held = suffix; entered = false }
    func release() { held = nil; gate?.resume(); gate = nil }
    func configureSecret() { badSecret = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        precondition(request.url?.scheme == "https" && request.url?.host == "broker.example.test" && request.httpMethod == "POST")
        let path = request.url!.path
        if path.hasSuffix(held ?? "NEVER") { entered = true; await withCheckedContinuation { gate = $0 } }
        var result: [String: Any]
        if path == "/v1/attempts" {
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            precondition(object["challenge"]!.count == 43 && object["state"]!.count == 43 && object["verifier"] == nil)
            var url = URLComponents(string: "https://api.restream.io/login")!
            url.queryItems = ["response_type":"code", "client_id":"public-fixture", "redirect_uri":"https://broker.example.test/oauth/callback", "state":id + "." + String(repeating: "s", count:43)].map { .init(name:$0.key,value:$0.value) }
            result = ["attempt": id, "authorization_url": url.url!.absoluteString]
        } else if path.hasSuffix("forget") { result = ["disconnected":true] }
        else {
            result = ["access_token": path.hasSuffix("refresh") ? "rotated-access" : "accepted-access", "scope":["chat.read", "channels.read", "stream.read"], "expires_in":3600]
            if path.hasSuffix("complete") { result["session"] = id; result["credential"] = credential }
            if path.hasSuffix("refresh") { precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + credential) }
            if badSecret { result["refresh_token"] = "FORBIDDEN_PROVIDER_REFRESH" }
        }
        return (try JSONSerialization.data(withJSONObject: result), HTTPURLResponse(url: request.url!, statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    func count(_ suffix: String) -> Int { calls.filter { $0.url!.path.hasSuffix(suffix) }.count }
}
@main struct RestreamBrokerHarness {
    static func check(_ value: Bool) { precondition(value) }
    static func until(_ predicate: @Sendable () async -> Bool) async throws {
        for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        preconditionFailure("Owned broker boundary did not enter")
    }
    static func callback(_ attempt: RestreamBrokerAttempt) -> URL {
        var c = URLComponents(string:"streamchat://oauth")!; c.queryItems = [.init(name:"attempt",value:attempt.id),.init(name:"state",value:attempt.state)]; return c.url!
    }
    @MainActor static func main() async throws {
        let chat = RestreamChat(); precondition(!chat.hasCredentials && !chat.hasProviderAuthorization)
        chat.connect(); precondition(chat.status == .needsCredentials, "Unconfigured service cannot use legacy direct-native OAuth")
        for raw in ["http://broker.example.test", "https://user:secret@broker.example.test", "https://broker.example.test/path", "https://broker.example.test?key=secret"] {
            do { _ = try RestreamAuthBroker(origin:URL(string:raw)!); preconditionFailure("Unsafe broker origin accepted") } catch {}
        }
        let fixture = BrokerFixture(), client = try RestreamAuthBroker(origin:URL(string:"https://broker.example.test")!,send:{ try await fixture.send($0) })
        var persisted: [RestreamBrokerGrant?] = []
        let session = RestreamBrokerSession(client:client) { persisted.append($0); return true }
        let attempt = try await session.begin()
        precondition(!attempt.authorizationURL.absoluteString.contains(attempt.verifier))
        var wrong = URLComponents(url:callback(attempt),resolvingAgainstBaseURL:false)!; wrong.queryItems!.append(.init(name:"state",value:attempt.state))
        do { _ = try await client.complete(attempt,callback:wrong.url!); preconditionFailure("Duplicate state accepted") } catch {}
        check(await fixture.count("complete") == 0)
        let grant = try await session.complete(attempt,callback:callback(attempt))
        precondition(grant.access == "accepted-access" && persisted.count == 1 && grant.scopes.contains("stream.read"))
        let archive = String(decoding:try JSONEncoder().encode(grant),as:UTF8.self)
        precondition(!archive.contains("refresh_token") && !archive.contains("client_secret"))
        do { _ = try await session.complete(attempt,callback:callback(attempt)); preconditionFailure("Native attempt replay dispatched") } catch {}
        check(await fixture.count("complete") == 1)
        await fixture.hold("refresh")
        let first = Task { try await session.refresh() }
        try await until { await fixture.entered }
        let second = Task { try await session.refresh() }
        try await Task.sleep(for:.milliseconds(10)); check(await fixture.count("refresh") == 1)
        await fixture.release(); _ = try await first.value; _ = try await second.value
        precondition(session.grant?.access == "rotated-access" && persisted.count == 2)
        // A canceled identity/attempt cannot accept a noncooperative late reply.
        for phase in ["attempts", "complete", "refresh"] {
            if phase == "refresh" {
                let ready = try await session.begin(); _ = try await session.complete(ready,callback:callback(ready))
            }
            await fixture.hold(phase)
            let job = Task {
                if phase == "attempts" { _ = try await session.begin() }
                else if phase == "complete" {
                    let a = try await session.begin(); _ = try await session.complete(a,callback:callback(a))
                } else { _ = try await session.refresh() }
            }
            try await until { await fixture.entered }
            let count = persisted.count; session.cancel(); await fixture.release()
            do { try await job.value; preconditionFailure("Retired broker reply accepted") } catch is CancellationError {}
            precondition(persisted.count == count)
        }
        // Two workspaces share one machine credential authority. A new
        // authorization intent retires old future requests and held refreshes.
        let authority = RestreamBrokerAuthority()
        var machine: RestreamBrokerGrant? = grant
        let old = RestreamBrokerSession(client:client,grant:grant,authority:authority) { machine = $0; return true }
        let replacement = RestreamBrokerSession(client:client,grant:grant,authority:authority) { machine = $0; return true }
        await fixture.hold("refresh")
        let oldRefresh = Task { try await old.refresh() }
        try await until { await fixture.entered }
        let replacementAttempt = try await replacement.begin()
        _ = try await replacement.complete(replacementAttempt,callback:callback(replacementAttempt))
        let accepted = machine
        await fixture.release()
        do { _ = try await oldRefresh.value; preconditionFailure("Old workspace refresh replaced machine grant") } catch is CancellationError {}
        precondition(machine == accepted && old.authorizedGrant == nil && replacement.authorizedGrant != nil)
        let before = await fixture.count("refresh")
        do { _ = try await old.refresh(); preconditionFailure("Retired workspace dispatched future refresh") } catch {}
        check(await fixture.count("refresh") == before)
        old.forget(); precondition(machine == accepted, "Retired workspace sign-out erased the replacement grant")
        let badFixture = BrokerFixture(); await badFixture.configureSecret()
        let badClient = try RestreamAuthBroker(origin:client.origin,send:{ try await badFixture.send($0) })
        let bad = RestreamBrokerSession(client:badClient) { _ in preconditionFailure("Confidential provider token reached native persistence") }
        let a = try await bad.begin()
        do { _ = try await bad.complete(a,callback:callback(a)); preconditionFailure("Confidential token response accepted") } catch {}
        // Actual store retirement is independent of a failed Keychain delete.
        // A fresh process authority must not adopt that unchanged grant.
        var raw: String? = archive, retired = false
        let store = RestreamBrokerGrantStore(readGrant: { raw }, writeGrant: { _ in false },
            isRetired: { retired }, setRetired: { retired = $0; return true })
        let signoutAuthority = RestreamBrokerAuthority()
        let signout = RestreamBrokerSession(client:client,grant:store.load(),authority:signoutAuthority,persist:store.save)
        precondition(signout.authorizedGrant != nil && !signout.forget())
        precondition(retired && raw == archive && store.load() == nil)
        let relaunched = RestreamBrokerSession(client:client,grant:store.load(),authority:RestreamBrokerAuthority(),persist:store.save)
        precondition(relaunched.authorizedGrant == nil)
        // Pure cancellation preserves another workspace's healthy credential.
        let healthy = RestreamBrokerSession(client:client,grant:accepted,authority:authority) { _ in true }
        replacement.cancel(); precondition(healthy.authorizedGrant != nil && machine == accepted)
        chat.cancelConnection(); precondition(chat.status == .needsCredentials)
        // Failed persistence cannot create usable memory-only authority.
        let refused = RestreamBrokerSession(client:client) { _ in false }, r = try await refused.begin()
        do { _ = try await refused.complete(r,callback:callback(r)); preconditionFailure("Unpersisted grant became usable") } catch {}
        precondition(refused.grant == nil)
        print("PASS: actual native broker client/session + shipping Restream gate; S256/state/duplicate/replay, exact origin/callback, opaque-only persistence, coalesced refresh, retired begin/complete/refresh and write-failure fences; no real service, consent or Keychain")
    }
}
