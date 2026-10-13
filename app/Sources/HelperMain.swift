import Foundation
import Darwin

@main
struct HelperMain {
    static func main() {
        guard geteuid() == 0 else { fputs("Helper requires installer-managed root service\n", stderr); exit(1) }
        do {
            if CommandLine.arguments.dropFirst() == ["--recover"] {
                try checkDirectory(); try restoreOwnedSleep(); exit(0)
            }
            guard CommandLine.arguments.count == 1 else { throw HelperError.message("Invalid helper option") }
            try checkDirectory()
            let recovered = try markerExists()
            try restoreOwnedSleep()
            let helper = try Helper(recovered: recovered)
            try cleanTemporaryFiles(uid: helper.uid)
            helper.watchLid()
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let stop = { do { try helper.stop(); exit(0) } catch { exit(1) } }
            termination.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop)
            termination.resume(); interrupt.resume()
            helper.tick()
            let timer = Timer(timeInterval: 1, repeats: true) { _ in helper.tick() }
            RunLoop.main.add(timer, forMode: .common)
            withExtendedLifetime((helper, termination, interrupt, timer)) { RunLoop.main.run() }
        } catch { fputs("WakeGuard helper: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
