import Foundation
import os

let appLog = Logger(subsystem: "com.markowieck.MonitorInputSwitcher", category: "app")

func NSLogError(_ message: String) {
    appLog.error("\(message, privacy: .public)")
}

func NSLogInfo(_ message: String) {
    appLog.info("\(message, privacy: .public)")
}
