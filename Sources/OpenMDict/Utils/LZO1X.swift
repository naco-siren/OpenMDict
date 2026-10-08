//
//  LZO1X.swift
//  OpenMDict
//
//  Pure-Swift LZO1X decompressor, stream-compatible with liblzo2's
//  `lzo1x_decompress_safe()` (the format MDict 1.x uses for its key and
//  record blocks).
//
//  The decoder structure follows the MIT-licensed lzokay implementation
//  (https://github.com/AxioDL/lzokay, Copyright (c) 2018 Jack Andersen);
//  see THIRD-PARTY-NOTICES.md. It is a decoder only — the library never
//  compresses.
//
//  Safety: every read and write is bounds-checked, so a corrupt or
//  malicious stream can only make `decompress` throw, never read or write
//  outside the buffers it was given.
//

import Foundation

/// Errors thrown by ``LZO1X/decompress(_:expectedSize:)``.
enum LZO1XError: Error, Equatable, CustomStringConvertible {
    /// The stream ended in the middle of an instruction or literal run.
    case inputOverrun
    /// The stream wants to produce more bytes than the output buffer holds.
    case outputOverrun
    /// A match references bytes before the start of the output.
    case lookbehindOverrun
    /// The stream reached its end-of-stream marker with bytes left over.
    case inputNotConsumed(trailingBytes: Int)

    var description: String {
        switch self {
        case .inputOverrun: return "LZO1X: input overrun (truncated stream)"
        case .outputOverrun: return "LZO1X: output overrun (stream longer than declared size)"
        case .lookbehindOverrun: return "LZO1X: lookbehind overrun (match before start of output)"
        case .inputNotConsumed(let n): return "LZO1X: \(n) trailing byte(s) after end-of-stream marker"
        }
    }
}

enum LZO1X {

    /// Decompress an LZO1X stream.
    ///
    /// - Parameters:
    ///   - input: The raw compressed stream (no container header).
    ///   - expectedSize: Capacity of the output; the stream may legitimately
    ///     decode to fewer bytes, in which case the result is shorter.
    /// - Returns: The decoded bytes.
    /// - Throws: ``LZO1XError`` for truncated, oversized or malformed input.
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            guard expectedSize == 0 else { throw LZO1XError.outputOverrun }
            _ = try input.withUnsafeBytes { src in
                try decompress(src, into: UnsafeMutableRawBufferPointer(start: nil, count: 0))
            }
            return Data()
        }
        // Allocate without zero-filling: every byte up to `written` is
        // produced by the decoder, and the rest is trimmed below.
        guard let raw = malloc(expectedSize) else { throw LZO1XError.outputOverrun }
        var output = Data(bytesNoCopy: raw, count: expectedSize, deallocator: .free)
        let written = try input.withUnsafeBytes { src in
            try output.withUnsafeMutableBytes { dst in
                try decompress(src, into: dst)
            }
        }
        return written < expectedSize ? output.prefix(written) : output
    }

    /// Decompress `src` into `dst`, returning the number of bytes written.
    ///
    /// `dst` is used as the output capacity; a stream that would exceed it
    /// throws ``LZO1XError/outputOverrun`` rather than writing past the end.
    @discardableResult
    static func decompress(_ src: UnsafeRawBufferPointer,
                           into dst: UnsafeMutableRawBufferPointer) throws -> Int {
        // Shortest valid stream is the bare end-of-stream marker (0x11 0x00 0x00).
        guard src.count >= 3, let inBase = src.baseAddress else {
            throw LZO1XError.inputOverrun
        }
        let inp = inBase.assumingMemoryBound(to: UInt8.self)

        if let outBase = dst.baseAddress, dst.count > 0 {
            return try run(inp, src.count, outBase.assumingMemoryBound(to: UInt8.self), dst.count)
        }
        // Zero-capacity output: only a stream that produces nothing is valid.
        // Every write is guarded by the capacity check, so a dummy byte is
        // never actually touched.
        var dummy: UInt8 = 0
        return try withUnsafeMutablePointer(to: &dummy) { try run(inp, src.count, $0, 0) }
    }

    // MARK: - Match copy

    /// Copy `length` bytes that start `distance` bytes behind the write
    /// position. The caller has already verified `distance <= op` and that
    /// `length` bytes fit in `capacity`.
    @inline(__always)
    private static func copyMatch(_ outp: UnsafeMutablePointer<UInt8>, _ op: inout Int,
                                  distance: Int, length: Int, capacity: Int) {
        let from = op &- distance
        if distance >= length {
            // Source and destination do not overlap.
            if length <= 8 && capacity &- op >= 8 && distance >= 8 {
                // Short match (the common M1/M2 case): one unaligned 8-byte
                // move; the bytes past `length` are overwritten by whatever
                // comes next and never exceed the buffer.
                let v = UnsafeRawPointer(outp + from).loadUnaligned(as: UInt64.self)
                UnsafeMutableRawPointer(outp + op).storeBytes(of: v, as: UInt64.self)
            } else {
                (outp + op).update(from: outp + from, count: length)
            }
            op &+= length
        } else if distance == 1 {
            // Run of a single byte.
            (outp + op).update(repeating: outp[from], count: length)
            op &+= length
        } else {
            // Overlapping copy: the pattern has period `distance`. Each pass
            // copies everything already produced since `from`, which is a
            // whole number of periods, so the available source doubles.
            var remaining = length
            while remaining > 0 {
                let n = min(remaining, op &- from)
                (outp + op).update(from: outp + from, count: n)
                op &+= n
                remaining &-= n
            }
        }
    }

    // MARK: - Core

    private static func run(_ inp: UnsafePointer<UInt8>, _ inCount: Int,
                            _ outp: UnsafeMutablePointer<UInt8>, _ outCount: Int) throws -> Int {
        var ip = 0      // next input byte
        var op = 0      // next output byte
        // Literals copied by the previous instruction: 0, 1...3, or 4 meaning
        // "four or more". Decides how an instruction byte < 16 is interpreted.
        var state = 0

        @inline(__always) func needIn(_ n: Int) throws {
            if n > inCount &- ip { throw LZO1XError.inputOverrun }
        }
        @inline(__always) func needOut(_ n: Int) throws {
            if n > outCount &- op { throw LZO1XError.outputOverrun }
        }
        @inline(__always) func copyLiterals(_ n: Int) throws {
            try needIn(n)
            try needOut(n)
            (outp + op).update(from: inp + ip, count: n)
            ip &+= n
            op &+= n
        }
        /// Extended-length prefix: each zero byte adds 255. Consumes the zeros
        /// and guarantees the following (non-zero) byte is readable.
        @inline(__always) func extendedLength() throws -> Int {
            var zeros = 0
            while true {
                try needIn(1)
                if inp[ip] != 0 { break }
                zeros &+= 1
                ip &+= 1
            }
            // Keep `zeros * 255 + base + 255` representable on every Int width
            // (the references cap this too); such a stream can never be valid.
            guard zeros <= Int.max / 255 &- 2 else { throw LZO1XError.inputOverrun }
            return zeros &* 255
        }
        @inline(__always) func readLE16() throws -> Int {
            try needIn(2)
            let v = Int(inp[ip]) | (Int(inp[ip &+ 1]) << 8)
            ip &+= 2
            return v
        }

        // ── First byte ────────────────────────────────────────────────────
        // 18...21: copy 1...4 literals (state = that count)
        // 22...255: copy (byte - 17) literals (state = 4)
        // 0...17: an ordinary instruction, handled by the loop below
        let first = Int(inp[0])
        if first >= 22 {
            ip = 1
            try copyLiterals(first &- 17)
            state = 4
        } else if first >= 18 {
            ip = 1
            let n = first &- 17
            try copyLiterals(n)
            state = n
        }

        // ── Instruction loop ──────────────────────────────────────────────
        while true {
            try needIn(1)
            let inst = Int(inp[ip])
            ip &+= 1

            var distance: Int   // lookbehind distance (≥ 1)
            var length: Int     // match length
            var trailing: Int   // literals that follow the match (0...3)

            if inst & 0xC0 != 0 {
                // M2  1LLDDDSS / 01LDDDSS + H : length 3...8, distance (H<<3)+D+1 ≤ 2048
                try needIn(1)
                distance = (Int(inp[ip]) << 3) &+ ((inst >> 2) & 7) &+ 1
                ip &+= 1
                length = (inst >> 5) &+ 1
                trailing = inst & 3
            } else if inst & 0x20 != 0 {
                // M3  001LLLLL [ext] + LE16 : length 2+L (L=0 → extended), distance D+1 ≤ 16384
                length = (inst & 0x1F) &+ 2
                if length == 2 {
                    let ext = try extendedLength()
                    length &+= ext &+ 31 &+ Int(inp[ip])
                    ip &+= 1
                }
                let le = try readLE16()
                distance = (le >> 2) &+ 1
                trailing = le & 3
            } else if inst & 0x10 != 0 {
                // M4  0001HLLL [ext] + LE16 : length 2+L, distance 16384+(H<<14)+D;
                //     a distance of exactly 0 (before the +16384) is the end-of-stream marker.
                length = (inst & 7) &+ 2
                if length == 2 {
                    let ext = try extendedLength()
                    length &+= ext &+ 7 &+ Int(inp[ip])
                    ip &+= 1
                }
                let le = try readLE16()
                distance = ((inst & 8) << 11) &+ (le >> 2)
                trailing = le & 3
                if distance == 0 { break }      // end of stream
                distance &+= 16384
            } else if state == 0 {
                // 0000LLLL : literal run of 3+L bytes (L=0 → extended); next state is 4
                var count = inst &+ 3
                if count == 3 {
                    let ext = try extendedLength()
                    count &+= ext &+ 15 &+ Int(inp[ip])
                    ip &+= 1
                }
                try copyLiterals(count)
                state = 4
                continue
            } else if state != 4 {
                // M1 after 1...3 literals: 0000DDSS + H : 2-byte match, distance (H<<2)+D+1 ≤ 1024
                try needIn(1)
                distance = (inst >> 2) &+ (Int(inp[ip]) << 2) &+ 1
                ip &+= 1
                length = 2
                trailing = inst & 3
            } else {
                // M1 after ≥ 4 literals: 0000DDSS + H : 3-byte match, distance (H<<2)+D+2049
                try needIn(1)
                distance = (inst >> 2) &+ (Int(inp[ip]) << 2) &+ 2049
                ip &+= 1
                length = 3
                trailing = inst & 3
            }

            // ── Apply match + trailing literals ───────────────────────────
            guard distance <= op else { throw LZO1XError.lookbehindOverrun }
            try needIn(trailing)
            try needOut(length &+ trailing)

            copyMatch(outp, &op, distance: distance, length: length, capacity: outCount)
            if trailing > 0 {
                // 1...3 bytes: direct stores beat a memmove call here.
                outp[op] = inp[ip]
                if trailing > 1 {
                    outp[op &+ 1] = inp[ip &+ 1]
                    if trailing > 2 { outp[op &+ 2] = inp[ip &+ 2] }
                }
                ip &+= trailing
                op &+= trailing
            }
            state = trailing
        }

        if ip != inCount {
            throw LZO1XError.inputNotConsumed(trailingBytes: inCount &- ip)
        }
        return op
    }
}
