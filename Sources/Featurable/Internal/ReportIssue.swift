import Foundation

#if canImport(os)
import os
#endif

internal func reportIssue(
  _ message: @autoclosure () -> String? = nil,
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) {
  #if DEBUG
    runtimeWarn(message(), fileID: fileID, line: line)
  #endif
}

private func runtimeWarn(
  _ message: @autoclosure () -> String?,
  fileID: StaticString,
  line: UInt
) {
  #if canImport(os)
    guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
      print("🟣 \(fileID):\(line): \(message() ?? "")")
      return
    }

    let moduleName = String(
      Substring("\(fileID)".utf8.prefix { $0 != UTF8.CodeUnit(ascii: "/") })
    )
    var message = message() ?? ""
    if message.isEmpty {
      message = "Issue reported"
    }
    os_log(
      .fault,
      log: OSLog(subsystem: "com.apple.runtime-issues", category: moduleName),
      "%@",
      message
    )
  #else
    print("\(fileID):\(line): \(message() ?? "")")
  #endif
}
