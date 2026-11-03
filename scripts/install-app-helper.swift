import AppKit

// Use AppKit's normal termination request instead of killing processes by name.
// Settings and timer state remain in their existing user preferences domain.
func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail("Invalid installer helper arguments.") }
let destination = canonicalPath(URL(fileURLWithPath: CommandLine.arguments[1]))
let source = canonicalPath(URL(fileURLWithPath: CommandLine.arguments[2]))
let mode = CommandLine.arguments[3]
guard ["launch", "no-launch", "release"].contains(mode) else { fail("Invalid installation mode.") }
let isRelease = mode == "release"
let willLaunch = mode != "no-launch"
let allowedPaths: Set<String> = willLaunch ? [destination, source] : [destination]
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.pomodoro.menubar")
if willLaunch, !isRelease, running.contains(where: { application in
    guard let url = application.bundleURL else { return true }
    return !allowedPaths.contains(canonicalPath(url))
}) {
    fail("Quit the other Sessions copy before installing, or use --no-launch.")
}
let owned = running.filter { application in
    if isRelease { return true }
    guard let url = application.bundleURL else { return false }
    return allowedPaths.contains(canonicalPath(url))
}
for application in owned {
    guard application.terminate() else { fail("Quit Sessions manually, then run the installer again.") }
}
let deadline = Date().addingTimeInterval(10)
while owned.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard owned.allSatisfy(\.isTerminated) else {
    fail("Sessions is still closing. Run the installer again after it quits.")
}
if isRelease {
    for application in owned {
        if let url = application.bundleURL { print(canonicalPath(url)) }
    }
}
