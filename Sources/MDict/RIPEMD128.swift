import Foundation

/// RIPEMD-128 hash implementation for MDX encrypted index decryption
/// Used when Encrypted flag has bit 1 set (value 2 or 3)
struct RIPEMD128 {
    
    /// Verify implementation with known test vectors
    static func runTests() {
        // Test vector: RIPEMD-128("") = cdf26213a150dc3ecb610f18f6b38b46
        let emptyHash = hash(Data())
        let expected = "cdf26213a150dc3ecb610f18f6b38b46"
        let actual = emptyHash.map { String(format: "%02x", $0) }.joined()
        print("    [TEST] RIPEMD128('') = \(actual)")
        print("    [TEST] Expected:       \(expected)")
        print("    [TEST] Match: \(actual == expected)")
        
        // Test vector: RIPEMD-128("a") = 86be7afa339d0fc7cfc785e72f578d33
        let aHash = hash(Data("a".utf8))
        let expectedA = "86be7afa339d0fc7cfc785e72f578d33"
        let actualA = aHash.map { String(format: "%02x", $0) }.joined()
        print("    [TEST] RIPEMD128('a') = \(actualA)")
        print("    [TEST] Expected:        \(expectedA)")
        print("    [TEST] Match: \(actualA == expectedA)")
    }
    
    /// Compute RIPEMD-128 hash
    static func hash(_ data: Data) -> Data {
        var state: (UInt32, UInt32, UInt32, UInt32) = (
            0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
        )
        
        // Pad message
        var message = data
        let originalLength = UInt64(data.count) * 8
        
        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        
        // Append length in bits (little-endian)
        var lengthLE = originalLength.littleEndian
        message.append(Data(bytes: &lengthLE, count: 8))
        
        // Process 64-byte blocks
        for blockStart in stride(from: 0, to: message.count, by: 64) {
            let block = message.subdata(in: blockStart..<blockStart+64)
            processBlock(block, state: &state)
        }
        
        // Output hash (little-endian)
        var result = Data(count: 16)
        result.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: state.0.littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: state.1.littleEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: state.2.littleEndian, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: state.3.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        return result
    }
    
    private static func processBlock(_ block: Data, state: inout (UInt32, UInt32, UInt32, UInt32)) {
        // Parse block into 16 32-bit words (little-endian)
        var X = [UInt32](repeating: 0, count: 16)
        block.withUnsafeBytes { ptr in
            for i in 0..<16 {
                X[i] = ptr.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
            }
        }
        
        var (A, B, C, D) = state
        var (AA, BB, CC, DD) = state
        
        // Round functions
        func F(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        func G(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
        func H(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x | ~y) ^ z }
        func I(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & z) | (y & ~z) }
        
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x << n) | (x >> (32 - n))
        }
        
        // Constants
        let K: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC]
        let KK: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x00000000]
        
        // Message schedule
        let r: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
                        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
                        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2]
        
        let rr: [Int] = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
                         6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
                         15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
                         8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14]
        
        let s: [UInt32] = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
                           7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
                           11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
                           11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12]
        
        let ss: [UInt32] = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
                            9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
                            9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
                            15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8]
        
        // Left rounds
        for j in 0..<64 {
            let f: UInt32
            let k: UInt32
            
            switch j / 16 {
            case 0: f = F(B, C, D); k = K[0]
            case 1: f = G(B, C, D); k = K[1]
            case 2: f = H(B, C, D); k = K[2]
            default: f = I(B, C, D); k = K[3]
            }
            
            let T = rotl(A &+ f &+ X[r[j]] &+ k, s[j])
            A = D; D = C; C = B; B = T
        }
        
        // Right rounds
        for j in 0..<64 {
            let f: UInt32
            let k: UInt32
            
            switch j / 16 {
            case 0: f = I(BB, CC, DD); k = KK[0]
            case 1: f = H(BB, CC, DD); k = KK[1]
            case 2: f = G(BB, CC, DD); k = KK[2]
            default: f = F(BB, CC, DD); k = KK[3]
            }
            
            let T = rotl(AA &+ f &+ X[rr[j]] &+ k, ss[j])
            AA = DD; DD = CC; CC = BB; BB = T
        }
        
        // Final addition
        let T = state.1 &+ C &+ DD
        state.1 = state.2 &+ D &+ AA
        state.2 = state.3 &+ A &+ BB
        state.3 = state.0 &+ B &+ CC
        state.0 = T
    }
}

/// Decrypt keyword index block (Encrypted=2)
/// This decryption is based on RIPEMD-128 hash of checksum bytes + magic constant
struct KeyIndexDecryptor {
    
    /// Decrypt the compressed data portion of a keyword index block
    /// Key is derived from: ripemd128(checksum_bytes + pack('<L', 0x3695))
    /// where pack('<L', 0x3695) = bytes [0x95, 0x36, 0x00, 0x00]
    static func decrypt(_ data: Data, checksumBytes: Data) -> Data {
        // Key material: checksum_bytes + magic constant 0x3695 as little-endian
        var keyMaterial = Data(checksumBytes)
        keyMaterial.append(contentsOf: [0x95, 0x36, 0x00, 0x00])
        
        let key = RIPEMD128.hash(keyMaterial)
        
        print("    [CRYPTO] checksumBytes: \(checksumBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        print("    [CRYPTO] keyMaterial: \(keyMaterial.map { String(format: "%02X", $0) }.joined(separator: " "))")
        print("    [CRYPTO] ripemd128 key: \(key.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Decrypt: for each byte:
        // 1. Swap nibbles
        // 2. XOR with (previous_encrypted ^ index ^ key_byte)
        var result = Data(count: data.count)
        var previous: UInt8 = 0x36
        
        for i in 0..<data.count {
            let byte = data[i]
            let keyByte = key[i % key.count]
            let indexByte = UInt8(truncatingIfNeeded: i)
            
            // Step 1: swap nibbles
            let swapped = ((byte >> 4) | (byte << 4)) & 0xFF
            // Step 2: XOR chain
            let decrypted = swapped ^ previous ^ indexByte ^ keyByte
            
            result[i] = decrypted
            previous = byte  // Use ORIGINAL encrypted byte for next iteration
        }
        
        return result
    }
}
