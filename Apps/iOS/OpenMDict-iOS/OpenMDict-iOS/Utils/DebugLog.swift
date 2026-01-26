//
//  DebugLog.swift
//  OpenMDict-iOS
//
//

import UIKit

@inline(__always)
func debugLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    #if VERBOSE_LOGGING
    let filename = (file as NSString).lastPathComponent
    print("📐 [\(filename):\(line)] \(message())")
    #endif
}
