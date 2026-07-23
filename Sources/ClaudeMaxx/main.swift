import Foundation

let server = HookServer()
do {
    try server.start()
    print("Claude Maxx daemon listening on 127.0.0.1:8765")
} catch {
    FileHandle.standardError.write("HookServer failed to start: \(error)\n".data(using: .utf8)!)
}

// TODO(M1 app-bundle task): replace with NSApplication.run() once the menu
// bar UI lands; a headless daemon just needs to stay alive to service the
// NWListener's callback queue.
dispatchMain()
