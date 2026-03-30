// Demo 2 — ghostty_app_new() with stub callbacks (Ghostty v1.3.1 API)
// Build: ./build.sh
import Foundation
import AppKit

// Step 1: Init
let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
guard initResult == GHOSTTY_SUCCESS else {
    print("FAIL: ghostty_init() returned \(initResult)")
    exit(1)
}
print("ghostty_init() OK")

// Step 2: Config
guard let cfg = ghostty_config_new() else {
    print("FAIL: ghostty_config_new() returned nil")
    exit(1)
}
ghostty_config_load_default_files(cfg)
ghostty_config_finalize(cfg)
print("ghostty_config OK")

// Step 3: Runtime config with stub callbacks
var rtCfg = ghostty_runtime_config_s(
    userdata: nil,
    supports_selection_clipboard: false,
    wakeup_cb: { _ in
        print("[wakeup_cb] called")
    },
    action_cb: { app, target, action in
        print("[action_cb] tag=\(action.tag.rawValue)")
        return true
    },
    read_clipboard_cb: { userdata, loc, state in
        print("[read_clipboard_cb] called")
        return false
    },
    confirm_read_clipboard_cb: { userdata, str, state, request in
        print("[confirm_read_clipboard_cb] called")
    },
    write_clipboard_cb: { userdata, loc, content, len, confirm in
        print("[write_clipboard_cb] called")
    },
    close_surface_cb: { userdata, processAlive in
        print("[close_surface_cb] called")
    }
)

// Step 4: Create app
guard let app = ghostty_app_new(&rtCfg, cfg) else {
    ghostty_config_free(cfg)
    print("FAIL: ghostty_app_new() returned nil")
    exit(1)
}
ghostty_config_free(cfg)
print("PASS: ghostty_app_new() returned non-nil")

// Step 5: Free
ghostty_app_free(app)
print("ghostty_app_free() OK")
print("PASS: Demo 2 complete")
exit(0)
