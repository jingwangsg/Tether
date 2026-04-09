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

    func testMacTerminalLazyLoadsOlderHistory() throws {
        if externalConfig != nil {
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
        app.launchEnvironment["TETHER_TERMINAL_TEST_PREFETCH_DELAY_MS"] = "4000"
        app.launchEnvironment["TETHER_TERMINAL_TEST_PREFETCH_TRIGGER_RATIO"] = "0.99"
        app.launchEnvironment["TETHER_TERMINAL_TEST_TOP_TRIGGER_RATIO"] = "0.98"
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
        XCTAssertEqual(Self.uint64(primaryAttach, key: "tail_bytes"), 1_048_576)
        XCTAssertTrue(Self.isMissingOrNull(primaryAttach["offset"]))

        let primaryScrollback = try waitForEvent(named: "scrollback_info", timeout: 20) {
            ($0["role"] as? String) == "primary"
        }
        let initialLoadedFrom = try XCTUnwrap(Self.uint64(primaryScrollback, key: "loaded_from"))
        XCTAssertGreaterThan(initialLoadedFrom, 0)

        let terminal = terminalScrollView(in: app)
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))

        _ = try scrollUntilEvent(
            on: terminal,
            name: "prefetch_started",
            timeout: 40
        )

        let prefetchAttach = try waitForEvent(named: "attach_started", timeout: 10) {
            ($0["role"] as? String) == "prefetch"
        }
        let prefetchOffset = try XCTUnwrap(Self.uint64(prefetchAttach, key: "offset"))
        XCTAssertLessThan(prefetchOffset, initialLoadedFrom)
        XCTAssertTrue(Self.isMissingOrNull(prefetchAttach["tail_bytes"]))

        _ = try scrollUntilEvent(
            on: terminal,
            name: "swap_completed",
            timeout: 45
        )

        let readyEvent = try waitForEvent(named: "prefetch_ready", timeout: 10)
        let swapEvent = try waitForEvent(named: "swap_completed", timeout: 10)
        XCTAssertEqual(
            try XCTUnwrap(Self.uint64(readyEvent, key: "loaded_from")),
            prefetchOffset
        )
        XCTAssertLessThan(
            try XCTUnwrap(Self.uint64(swapEvent, key: "loaded_start_offset")),
            initialLoadedFrom
        )

        let debugState = try XCTUnwrap(Self.debugState(from: terminal))
        let currentLoaded = try XCTUnwrap(Self.uint64(debugState, key: "loaded_start_offset"))
        XCTAssertLessThan(currentLoaded, initialLoadedFrom)
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

    private func startServer() throws {
        let process = Process()
        process.currentDirectoryURL = repoRoot
        process.executableURL = repoRoot.appendingPathComponent("target/debug/tether-server")
        process.arguments = ["--port", "\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["TETHER_DATA_DIR"] = tempRoot.appendingPathComponent("data").path
        environment["RUST_LOG"] = "error"
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        serverProcess = process

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let response = try? jsonResponse(url: URL(string: "http://127.0.0.1:\(port)/api/info")!),
               response.statusCode == 200 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw UITestFailure(description: "tether-server did not become ready before timeout")
    }

    private func provisionSession(named sessionName: String) throws -> String {
        let scriptURL = tempRoot.appendingPathComponent("emit-history.sh")
        let script = """
        #!/bin/sh
        prefix=''
        j=0
        while [ "$j" -lt 128 ]; do
          prefix="${prefix}\\033[31m\\033[32m\\033[33m\\033[34m\\033[35m\\033[36m\\033[0m"
          j=$((j + 1))
        done
        i=0
        while [ "$i" -lt 1024 ]; do
          printf '%b' "$prefix"
          printf 'lazy-%06d line for mac lazy loading verification\\n' "$i"
          i=$((i + 1))
        done
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
                return sessionId
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        throw UITestFailure(description: "session did not become alive before timeout")
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

    private func sessionTileElement(in app: XCUIApplication) -> XCUIElement {
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

    private func openSession(in app: XCUIApplication) throws {
        let sessionTile = sessionTileElement(in: app)
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
