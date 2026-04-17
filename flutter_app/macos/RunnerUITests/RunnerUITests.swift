import XCTest

private struct UITestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct UITestConfig {
    let port: Int
    let sessionName: String

    static let sharedPath = URL(fileURLWithPath: "/tmp/tether-ui-config.json")

    static func load() -> UITestConfig? {
        guard let data = try? Data(contentsOf: sharedPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int,
              let sessionName = json["session_name"] as? String else {
            return nil
        }
        return UITestConfig(port: port, sessionName: sessionName)
    }
}

final class RunnerUITests: XCTestCase {
    private var tempRoot: URL!
    private var serverProcess: Process?
    private var serverLogURL: URL!
    private var eventLogURL: URL!
    private var repoRoot: URL!

    private var port: Int {
        externalConfig?.port ?? 17681
    }

    private var sessionName: String {
        externalConfig?.sessionName ?? "lazy-session"
    }

    private var externalConfig: UITestConfig? {
        UITestConfig.load()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        repoRoot = try Self.repoRoot()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        serverLogURL = tempRoot.appendingPathComponent("tether-server.log")
        eventLogURL = tempRoot.appendingPathComponent("terminal-events.jsonl")
    }

    override func tearDownWithError() throws {
        serverProcess?.terminate()
        serverProcess?.waitUntilExit()
        serverProcess = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testMacTerminalUsesSingleLargeInitialReplayWithoutLazyLoading() throws {
        if canReachConfiguredExternalServer() {
            try waitForExternalServer()
        } else {
            try ensureCargoBinary(named: "tether-server")
            try ensureCargoBinary(named: "tether-client")
            try startServer()
            _ = try provisionSession(named: sessionName)
        }

        let app = XCUIApplication()
        app.launchEnvironment["TETHER_CLIENT_PATH"] =
            repoRoot.appendingPathComponent("target/debug/tether-client").path
        app.launchEnvironment["TETHER_TERMINAL_TEST_LOG_PATH"] = eventLogURL.path
        app.launchEnvironment["TETHER_TERMINAL_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_TEST_AUTO_OPEN_SESSION_NAME"] = sessionName
        app.launchEnvironment["TETHER_TEST_SERVER_HOST"] = "127.0.0.1"
        app.launchEnvironment["TETHER_TEST_SERVER_PORT"] = "\(port)"
        app.launch()

        _ = try waitForEvent(named: "sessions_refreshed", timeout: 20) {
            guard let names = $0["session_names"] as? [Any] else {
                return false
            }
            return names.contains { ($0 as? String) == sessionName }
        }

        let primaryAttach = try waitForEvent(named: "attach_started", timeout: 20) {
            ($0["role"] as? String) == "primary"
        }
        XCTAssertEqual(Self.uint64(primaryAttach, key: "tail_bytes"), 33_554_432)
        XCTAssertTrue(Self.isMissingOrNull(primaryAttach["offset"]))

        let primaryScrollback = try waitForEvent(named: "scrollback_info", timeout: 20) {
            ($0["role"] as? String) == "primary"
        }
        let initialLoadedFrom = try XCTUnwrap(Self.uint64(primaryScrollback, key: "loaded_from"))
        if externalConfig == nil {
            XCTAssertGreaterThan(initialLoadedFrom, 0)
        }

        let terminal = terminalScrollView(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        try scrollToTop(on: terminal)
        try assertNoEvent(named: "prefetch_started", timeout: 3)
        try assertNoEvent(named: "prefetch_ready", timeout: 3)
        try assertNoEvent(named: "swap_completed", timeout: 3)
        XCTAssertEqual(try eventCount(named: "attach_started"), 1)
        XCTAssertEqual(try eventCount(named: "attach_started") { ($0["role"] as? String) == "primary" }, 1)

        let debugState = try XCTUnwrap(Self.debugState(from: terminal))
        XCTAssertEqual(debugState["is_at_top"] as? Bool, true)
        let currentLoaded = try XCTUnwrap(Self.uint64(debugState, key: "loaded_start_offset"))
        XCTAssertEqual(currentLoaded, initialLoadedFrom)
    }

    func testSidebarAttentionBellAppearsForBackgroundSession() throws {
        let runId = String(UUID().uuidString.prefix(8))
        let focusSessionName = "focus-\(runId)"
        let attentionSessionName = "attention-\(runId)"

        if canReachConfiguredExternalServer() {
            try waitForServerReady()
        } else {
            try ensureCargoBinary(named: "tether-server")
            try startServer()
        }
        try ensureCargoBinary(named: "tether-client")

        let groupId = try createGroup(named: "UI Bell Group \(runId)")
        _ = try provisionCommandSession(
            named: focusSessionName,
            groupId: groupId,
            command: "while :; do sleep 1; done"
        )
        let attentionSessionId = try provisionCommandSession(
            named: attentionSessionName,
            groupId: groupId,
            command:
                "sleep 1; printf '\\033]0;✱ Codex\\007'; sleep 8; printf '\\033]0;· Codex\\007'; while :; do sleep 1; done"
        )

        let app = XCUIApplication()
        app.launchEnvironment["TETHER_CLIENT_PATH"] =
            repoRoot.appendingPathComponent("target/debug/tether-client").path
        app.launchEnvironment["TETHER_TERMINAL_TEST_LOG_PATH"] = eventLogURL.path
        app.launchEnvironment["TETHER_TEST_AUTO_OPEN_SESSION_NAME"] = focusSessionName
        app.launchEnvironment["TETHER_TEST_SERVER_HOST"] = "127.0.0.1"
        app.launchEnvironment["TETHER_TEST_SERVER_PORT"] = "\(port)"
        app.launch()

        _ = try waitForEvent(named: "sessions_refreshed", timeout: 20) {
            guard let names = $0["session_names"] as? [Any] else {
                return false
            }
            return names.contains { ($0 as? String) == focusSessionName }
                && names.contains { ($0 as? String) == attentionSessionName }
        }

        _ = try waitForSession(id: attentionSessionId, timeout: 25) { session in
            let seq = Self.int(session, key: "attention_seq") ?? 0
            let ack = Self.int(session, key: "attention_ack_seq") ?? 0
            return seq > 0 && ack == 0
        }

        _ = try waitForEvent(named: "session_sidebar_status_visible", timeout: 10) {
            ($0["session_id"] as? String) == attentionSessionId
                && ($0["status"] as? String) == "attention"
        }
    }

    func testActiveSessionAcknowledgesAttentionAndShowsWaitingIndicator() throws {
        let runId = String(UUID().uuidString.prefix(8))
        let attentionSessionName = "attention-\(runId)"

        if canReachConfiguredExternalServer() {
            try waitForServerReady()
        } else {
            try ensureCargoBinary(named: "tether-server")
            try startServer()
        }
        try ensureCargoBinary(named: "tether-client")

        let groupId = try createGroup(named: "UI Bell Active Group \(runId)")
        let attentionSessionId = try provisionCommandSession(
            named: attentionSessionName,
            groupId: groupId,
            command:
                "sleep 1; printf '\\033]0;✱ Codex\\007'; sleep 8; printf '\\033]0;· Codex\\007'; while :; do sleep 1; done"
        )

        let app = XCUIApplication()
        app.launchEnvironment["TETHER_CLIENT_PATH"] =
            repoRoot.appendingPathComponent("target/debug/tether-client").path
        app.launchEnvironment["TETHER_TERMINAL_TEST_LOG_PATH"] = eventLogURL.path
        app.launchEnvironment["TETHER_TEST_AUTO_OPEN_SESSION_NAME"] = attentionSessionName
        app.launchEnvironment["TETHER_TEST_SERVER_HOST"] = "127.0.0.1"
        app.launchEnvironment["TETHER_TEST_SERVER_PORT"] = "\(port)"
        app.launch()

        _ = try waitForEvent(named: "sessions_refreshed", timeout: 20) {
            guard let names = $0["session_names"] as? [Any] else {
                return false
            }
            return names.contains { ($0 as? String) == attentionSessionName }
        }

        _ = try waitForSession(id: attentionSessionId, timeout: 25) { session in
            let seq = Self.int(session, key: "attention_seq") ?? 0
            let ack = Self.int(session, key: "attention_ack_seq") ?? 0
            return seq > 0 && ack == seq
        }

        _ = try waitForEvent(named: "session_sidebar_status_visible", timeout: 10) {
            ($0["session_id"] as? String) == attentionSessionId
                && ($0["status"] as? String) == "waiting"
        }
    }

    private func waitForExternalServer() throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let response = try? jsonArrayResponse(url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!),
               response.contains(where: { ($0["name"] as? String) == sessionName }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw UITestFailure(description: "external UI test server was not ready")
    }

    private func canReachConfiguredExternalServer() -> Bool {
        guard externalConfig != nil else {
            return false
        }
        guard let response = try? jsonResponse(url: URL(string: "http://127.0.0.1:\(port)/api/info")!) else {
            return false
        }
        return response.statusCode == 200
    }

    private func waitForServerReady() throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let response = try? jsonResponse(url: URL(string: "http://127.0.0.1:\(port)/api/info")!),
               response.statusCode == 200 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw UITestFailure(description: "UI test server was not ready")
    }

    private func startServer() throws {
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = repoRoot.appendingPathComponent("target/debug/tether-server")
        process.arguments = ["--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["TETHER_DATA_DIR"] = tempRoot.appendingPathComponent("data").path
        environment["RUST_LOG"] = "error"
        process.environment = environment
        FileManager.default.createFile(atPath: serverLogURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: serverLogURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        serverProcess = process

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !process.isRunning {
                break
            }
            if let response = try? jsonResponse(url: URL(string: "http://127.0.0.1:\(port)/api/info")!),
               response.statusCode == 200 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let log =
            ((try? String(contentsOf: serverLogURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "<no server log>"
        let exitStatus = process.isRunning ? "still running" : "exited with \(process.terminationStatus)"
        throw UITestFailure(
            description: "tether-server did not become ready before timeout (\(exitStatus))\n\(log)"
        )
    }

    private func provisionSession(named sessionName: String) throws -> String {
        let scriptURL = tempRoot.appendingPathComponent("emit-history.sh")
        let readyURL = tempRoot.appendingPathComponent("emit-history.ready")
        let script = """
        #!/bin/sh
        prefix=''
        j=0
        while [ "$j" -lt 128 ]; do
          prefix="${prefix}\\033[31m\\033[32m\\033[33m\\033[34m\\033[35m\\033[36m\\033[0m"
          j=$((j + 1))
        done
        i=0
        while [ "$i" -lt 8192 ]; do
          printf '%b' "$prefix"
          printf 'lazy-%06d line for mac lazy loading verification\\n' "$i"
          i=$((i + 1))
        done
        touch "\(readyURL.path)"
        while :; do
          sleep 1
        done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let groupResponse = try jsonResponse(
            url: URL(string: "http://127.0.0.1:\(port)/api/groups")!,
            method: "POST",
            body: [
                "name": "UI Lazy Group",
                "default_cwd": tempRoot.path,
            ]
        )
        XCTAssertEqual(groupResponse.statusCode, 201)
        let groupId = try XCTUnwrap(groupResponse.json["id"] as? String)

        let sessionResponse = try jsonResponse(
            url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!,
            method: "POST",
            body: [
                "group_id": groupId,
                "name": sessionName,
                "command": scriptURL.path,
                "cwd": tempRoot.path,
            ]
        )
        XCTAssertEqual(sessionResponse.statusCode, 201)
        let sessionId = try XCTUnwrap(sessionResponse.json["id"] as? String)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let sessions = try jsonArrayResponse(url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!)
            if let row = sessions.first(where: { ($0["id"] as? String) == sessionId }),
               let isAlive = row["is_alive"] as? Bool,
               isAlive {
                try waitForFile(at: readyURL, timeout: 20, description: "ui history fixture ready file")
                return sessionId
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw UITestFailure(description: "session did not become alive before timeout")
    }

    private func createGroup(named name: String) throws -> String {
        let groupResponse = try jsonResponse(
            url: URL(string: "http://127.0.0.1:\(port)/api/groups")!,
            method: "POST",
            body: [
                "name": name,
                "default_cwd": tempRoot.path,
            ]
        )
        XCTAssertEqual(groupResponse.statusCode, 201)
        return try XCTUnwrap(groupResponse.json["id"] as? String)
    }

    private func provisionCommandSession(
        named sessionName: String,
        groupId: String,
        command: String
    ) throws -> String {
        let sessionResponse = try jsonResponse(
            url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!,
            method: "POST",
            body: [
                "group_id": groupId,
                "name": sessionName,
                "command": command,
                "cwd": tempRoot.path,
            ]
        )
        XCTAssertEqual(sessionResponse.statusCode, 201)
        let sessionId = try XCTUnwrap(sessionResponse.json["id"] as? String)

        _ = try waitForSession(id: sessionId, timeout: 15) {
            ($0["is_alive"] as? Bool) == true
        }
        return sessionId
    }

    private func scrollUntilEvent(
        on terminal: XCUIElement,
        name: String,
        timeout: TimeInterval,
        alsoExpecting overlay: XCUIElement? = nil
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var sawOverlay = false
        while Date() < deadline {
            if try latestEvent(named: name) != nil {
                return sawOverlay
            }
            terminal.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if overlay?.exists == true {
                sawOverlay = true
            }
        }

        throw UITestFailure(description: "timed out waiting for \(name)")
    }

    private func scrollToTop(on terminal: XCUIElement) throws {
        for _ in 0..<20 {
            terminal.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let debugState = Self.debugState(from: terminal),
               (debugState["is_at_top"] as? Bool) == true {
                return
            }
        }
        throw UITestFailure(description: "timed out reaching terminal top")
    }

    private func assertNoEvent(
        named name: String,
        timeout: TimeInterval,
        where predicate: ([String: Any]) -> Bool = { _ in true }
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = try latestEvent(named: name, where: predicate) {
                throw UITestFailure(description: "unexpected event \(name): \(event)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func eventCount(
        named name: String,
        where predicate: ([String: Any]) -> Bool = { _ in true }
    ) throws -> Int {
        try readEvents().filter { ($0["event"] as? String) == name && predicate($0) }.count
    }

    private func waitForFile(
        at url: URL,
        timeout: TimeInterval,
        description: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw UITestFailure(description: "timed out waiting for \(description)")
    }

    private func waitForEvent(
        named name: String,
        timeout: TimeInterval,
        where predicate: ([String: Any]) -> Bool = { _ in true }
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = try latestEvent(named: name, where: predicate) {
                return event
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw UITestFailure(description: "timed out waiting for event \(name)")
    }

    private func latestEvent(
        named name: String,
        where predicate: ([String: Any]) -> Bool = { _ in true }
    ) throws -> [String: Any]? {
        try readEvents()
            .reversed()
            .first { ($0["event"] as? String) == name && predicate($0) }
    }

    private func readEvents() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: eventLogURL.path) else { return [] }
        let contents = try String(contentsOf: eventLogURL, encoding: .utf8)
        return contents
            .split(separator: "\n")
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return json
            }
    }

    private func terminalScrollView(in app: XCUIApplication) -> XCUIElement {
        let direct = app.scrollViews["terminal-scroll-view"]
        if direct.exists {
            return direct
        }
        return app.descendants(matching: .any)
            .matching(identifier: "terminal-scroll-view")
            .firstMatch
    }

    private func sessionTileElement(in app: XCUIApplication, named sessionName: String) -> XCUIElement {
        let byLabelButton = app.buttons[sessionName]
        if byLabelButton.exists {
            return byLabelButton
        }
        let byAnyLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", sessionName))
            .firstMatch
        if byAnyLabel.exists {
            return byAnyLabel
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-tile-"))
            .matching(NSPredicate(format: "label == %@", sessionName))
            .firstMatch
    }

    private func sessionStatusElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func waitForSessionTileValue(
        in app: XCUIApplication,
        sessionName: String,
        contains expected: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabel = "<missing>"
        var lastValue = "<missing>"
        while Date() < deadline {
            let tile = sessionTileElement(in: app, named: sessionName)
            if tile.exists {
                lastLabel = tile.label
                lastValue = (tile.value as? String) ?? "<nil>"
                if lastLabel.localizedCaseInsensitiveContains(expected)
                    || lastValue.localizedCaseInsensitiveContains(expected) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw UITestFailure(
            description:
                "timed out waiting for session tile \(sessionName) to contain \(expected) (label=\(lastLabel), value=\(lastValue))"
        )
    }

    private func waitForStatusValue(
        in app: XCUIApplication,
        identifier: String,
        equals expected: String,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = sessionStatusElement(in: app, identifier: identifier)
            if status.exists {
                let label = status.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = (status.value as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if label == expected || value == expected {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw UITestFailure(description: "timed out waiting for status \(identifier) to equal \(expected)")
    }

    private func waitForSession(
        id sessionId: String,
        timeout: TimeInterval,
        where predicate: ([String: Any]) -> Bool = { _ in true }
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sessions = try jsonArrayResponse(url: URL(string: "http://127.0.0.1:\(port)/api/sessions")!)
            if let row = sessions.first(where: { ($0["id"] as? String) == sessionId && predicate($0) }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw UITestFailure(description: "timed out waiting for session \(sessionId)")
    }

    private func openSession(in app: XCUIApplication, named sessionName: String) throws {
        let sessionTile = sessionTileElement(in: app, named: sessionName)
        if sessionTile.waitForExistence(timeout: 2) {
            sessionTile.click()
            return
        }

        let candidateOffsets = [
            CGVector(dx: 0.11, dy: 0.18),
            CGVector(dx: 0.16, dy: 0.18),
            CGVector(dx: 0.11, dy: 0.22),
        ]
        for offset in candidateOffsets {
            let content = app.windows.element(boundBy: 0).groups.element(boundBy: 0)
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            app.activate()
            content.coordinate(withNormalizedOffset: offset).click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func jsonResponse(
        url: URL,
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> (statusCode: Int, json: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let result = try synchronousData(for: request)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        )
        return (result.statusCode, json)
    }

    private func jsonArrayResponse(url: URL) throws -> [[String: Any]] {
        let result = try synchronousData(for: URLRequest(url: url))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.data) as? [[String: Any]]
        )
    }

    private func synchronousData(for request: URLRequest) throws -> (data: Data, statusCode: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var responseCode = 0
        var capturedError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                capturedError = error
                return
            }
            payload = data
            responseCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        }.resume()

        semaphore.wait()
        if let capturedError {
            throw capturedError
        }
        return (try XCTUnwrap(payload), responseCode)
    }

    private func ensureCargoBinary(named binaryName: String) throws {
        let binaryURL = repoRoot.appendingPathComponent("target/debug/\(binaryName)")
        guard !FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return }

        let build = Process()
        build.currentDirectoryURL = repoRoot
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["cargo", "build", "-p", binaryName]
        try build.run()
        build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0)
    }

    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw UITestFailure(description: "failed to resolve repo root")
    }

    private static func int(_ payload: [String: Any], key: String) -> Int? {
        if let value = payload[key] as? NSNumber {
            return value.intValue
        }
        if let value = payload[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func uint64(_ payload: [String: Any], key: String) -> UInt64? {
        if let value = payload[key] as? NSNumber {
            return value.uint64Value
        }
        if let value = payload[key] as? String {
            return UInt64(value)
        }
        return nil
    }

    private static func isMissingOrNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func debugState(from terminal: XCUIElement) -> [String: Any]? {
        guard let raw = terminal.value as? String,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
