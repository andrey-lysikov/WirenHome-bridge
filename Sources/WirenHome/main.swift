//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Bridge
import Common
import Dispatch
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print(AppVersion.current)
    exit(0)
}

let runner: BridgeRunner
do {
    let settings = try Settings.load(arguments: arguments)
    Log.info("wb-homekit \(AppVersion.current), MQTT \(settings.mqtt.host):\(settings.mqtt.port), data \(settings.dataDirectory)")
    runner = try BridgeRunner(settings: settings, version: AppVersion.current)
} catch {
    Log.error("\(error)")
    exit(1)
}

// systemd stops the service with SIGTERM; report the stopped status before exiting.
func installSignalHandlers(_ runner: BridgeRunner) -> [any DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task {
                await runner.stop()
                exit(0)
            }
        }
        source.resume()
        return source
    }
}

let signalSources = installSignalHandlers(runner)
await runner.run()
withExtendedLifetime(signalSources) {}
