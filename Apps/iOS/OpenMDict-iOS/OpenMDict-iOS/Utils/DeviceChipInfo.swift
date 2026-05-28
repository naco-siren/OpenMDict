//
//  DeviceChipInfo.swift
//  OpenMDict-iOS
//
//  Minimal chip-name probe. Goal: feed into a ComputeProfile decision for
//  article-content indexing — A13 (iPhone 11) measures *slower* on GPU
//  than CPU for MiniLM-L6 (~45/s vs ~187/s), so we want to gate the
//  foreground `.cpuAndGPU` profile to chips where the GPU actually wins.
//  This file just reports what's available; tier logic comes after we
//  see the values on a few devices.
//
//  Sources tried (best-effort, any may return nil on simulator or under
//  sandbox restrictions):
//    • `machdep.cpu.brand_string` — marketing CPU name (e.g. "Apple A13
//       Bionic" / "Apple M1"). Empirically the most legible on iOS.
//    • `hw.model` — device identifier (e.g. "iPhone12,1" for iPhone 11).
//       Lets us map a device → chip when the brand string is empty.
//    • `hw.machine` — CPU architecture / machine name; iOS app usually
//       returns the same as hw.model.
//    • `MTLDevice.name` — Metal device name (e.g. "Apple A13 GPU").
//       The simplest way to get the GPU's marketing name.
//
//  Not committed: this is an exploration step. If we keep the
//  ComputeProfile tier logic, the chip-name parsing moves into a tier
//  enum (e.g. `.preferCPU` / `.preferGPU`) and this file can shrink.
//

import Darwin
import Metal

enum DeviceChipInfo {

    /// Marketing CPU name, e.g. "Apple A13 Bionic" or "Apple M1".
    static var brand: String? { sysctlString("machdep.cpu.brand_string") }

    /// Hardware model identifier, e.g. "iPhone12,1" (iPhone 11) / "iPhone17,1".
    static var model: String? { sysctlString("hw.model") }

    /// CPU architecture / machine name; on iOS app context typically the
    /// same as `hw.model` (iOS returns the device identifier).
    static var machine: String? { sysctlString("hw.machine") }

    /// Metal device's reported name, e.g. "Apple A13 GPU".
    static var gpuName: String? { MTLCreateSystemDefaultDevice()?.name }

    /// Compact one-line summary suitable for `print`/`log.info`.
    static var summary: String {
        "chip=\(brand ?? "?") model=\(model ?? "?") machine=\(machine ?? "?") gpu=\(gpuName ?? "?")"
    }

    /// `true` on chips where the foreground `.cpuAndGPU` profile is
    /// SLOWER than `.cpuOnly` for our MiniLM-L6 encode loop, so the
    /// dispatcher should downgrade `.foreground` requests to `.cpuOnly`.
    ///
    /// Confirmed empirically on **A13 / iPhone 11**: ~45/s on GPU vs
    /// ~187/s on CPU. Small-model GPU scheduling overhead outweighs
    /// parallel-algebra savings on this generation. A11/A12 included
    /// defensively — they don't run iOS 26 so the article-search
    /// feature can't actually reach this code path on them, but the
    /// rule reads cleaner stated as "old A-series chips".
    ///
    /// Detection key: `MTLDevice.name` is the format
    /// "Apple <Chip> GPU" on every iPhone / iPad we've seen (A8X, A10,
    /// A13 verified). For M-series Macs it's "Apple M<N>[ <Variant>]
    /// GPU"; M-series isn't in this opt-out, they go through GPU.
    static var prefersCPUForeground: Bool {
        let gpu = gpuName ?? ""
        return gpu.contains("A13") || gpu.contains("A12") || gpu.contains("A11")
    }

    /// sysctlbyname wrapper that returns the value as a UTF-8 String
    /// (or nil if the sysctl is absent / errors out).
    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        // Drop sysctl's trailing NUL before UTF-8 decode (Swift 6's
        // `String(cString:)` overload is deprecated for arrays).
        let nulIdx = buf.firstIndex(of: 0) ?? buf.count
        let bytes = buf[..<nulIdx].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
