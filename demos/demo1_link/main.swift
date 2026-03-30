// Demo 1 — ghostty_init() + link test (Ghostty v1.3.1)
// Build: ./build.sh
import Foundation

let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
print("ghostty_init() returned: \(result)")

if result == GHOSTTY_SUCCESS {
    print("PASS: libghostty linked and initialized successfully")
    exit(0)
} else {
    print("FAIL: ghostty_init() returned non-zero: \(result)")
    exit(1)
}
