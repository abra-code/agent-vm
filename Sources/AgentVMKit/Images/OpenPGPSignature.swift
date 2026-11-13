// Sources/AgentVMKit/Images/OpenPGPSignature.swift
//
// Checks the OpenPGP signature (RFC 9580) a distribution puts on its cloud image's checksum list:
// Ubuntu's detached SHA256SUMS.gpg, Fedora's clear-signed CHECKSUM. Only what those use is read:
// version 4 signature and public key packets, RSA keys, SHA-256 and SHA-512, binary (0x00) and
// text (0x01) signatures; anything else is refused. The key is pinned: the signature must be made by
// the primary key whose fingerprint the base names, and the key's material comes with agent-vm
// (LinuxSigningKeys), never from the network. The key's own certifications, expiry and revocation
// are not read: the pinned fingerprint is the trust, as a distribution's keyring package is for its
// own tools. CryptoKit hashes; the Security framework checks the RSA signature.

import CryptoKit
import Foundation
import Security

enum OpenPGP {
    struct Problem: Error, Equatable, CustomStringConvertible {
        var description: String
        init(_ description: String) {
            self.description = description
        }
    }

    /// An RSA public key of a key block, with its version 4 fingerprint (20 bytes).
    struct PublicKey: Equatable {
        var fingerprint: [UInt8]
        var modulus: [UInt8]
        var exponent: [UInt8]
    }

    struct Signature: Equatable {
        var type: UInt8
        var hashAlgorithm: UInt8
        /// From the version octet through the hashed subpackets: what the hash covers after the data.
        var hashedPart: [UInt8]
        var issuerFingerprint: [UInt8]?
        var issuerKeyID: [UInt8]?
        var left16: [UInt8]
        var value: [UInt8]
    }

    // MARK: Verifying

    /// Checks a detached signature (binary, or ASCII armored) of `data` by the key with `fingerprint`
    /// (40 hexadecimal digits) in the armored key block `key`.
    static func verifyDetached(data: Data, signature: Data, key: String, fingerprint: String) throws {
        let bytes: [UInt8]
        if let text = String(data: signature, encoding: .utf8), text.contains("-----BEGIN PGP SIGNATURE-----") {
            bytes = try dearmor(text, kind: "SIGNATURE")
        } else {
            bytes = [UInt8](signature)
        }
        let signature = try onlySignature(in: bytes)
        // A detached signature of a file's bytes; a text signature would hash canonical text instead
        guard signature.type == 0x00 else {
            throw Problem("a detached signature that is not of binary data (type \(signature.type))")
        }
        try verify(data: [UInt8](data), signature: signature, keys: try publicKeys(armored: key), fingerprint: fingerprint)
    }

    /// Checks a clear-signed message and returns the text that was signed (dash escapes removed,
    /// lines joined by "\n"); nothing outside the signed part is returned.
    static func verifyCleartext(_ message: String, key: String, fingerprint: String) throws -> String {
        let lines = splitLines(message)
        guard let begin = lines.firstIndex(of: "-----BEGIN PGP SIGNED MESSAGE-----") else {
            throw Problem("no clear-signed message in it")
        }
        var index = begin + 1
        var hashNames: [String] = []
        while index < lines.count, !lines[index].isEmpty {
            let header = lines[index]
            guard header.hasPrefix("Hash: ") else {
                throw Problem("an unknown clear-signed header: \(Printable.line(String(header), limit: 60))")
            }
            hashNames += header.dropFirst("Hash: ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            index += 1
        }
        index += 1
        var signed: [Substring] = []
        while index < lines.count, lines[index] != "-----BEGIN PGP SIGNATURE-----" {
            let line = lines[index]
            signed.append(line.hasPrefix("- ") ? line.dropFirst(2) : line)
            index += 1
        }
        guard index < lines.count else {
            throw Problem("the clear-signed message has no signature")
        }
        let armored = lines[index...].joined(separator: "\n")
        let signature = try onlySignature(in: try dearmor(armored, kind: "SIGNATURE"))
        guard signature.type == 0x01 else {
            throw Problem("a clear-signed message's signature is not of text (type \(signature.type))")
        }
        guard hashNames.contains(hashName(signature.hashAlgorithm)) else {
            throw Problem("the message names hash \(hashNames.joined(separator: ", ")), its signature uses \(hashName(signature.hashAlgorithm))")
        }
        // The signed text: each line without its trailing spaces and tabs, lines joined by CR LF, the
        // line break before the signature not part of it.
        let canonical = signed.map { line -> String in
            var trimmed = String(line)
            while let last = trimmed.last, last == " " || last == "\t" {
                trimmed.removeLast()
            }
            return trimmed
        }
        try verify(data: Array(canonical.joined(separator: "\r\n").utf8), signature: signature, keys: try publicKeys(armored: key), fingerprint: fingerprint)
        // What was signed, and only that: trailing whitespace anyone may have added is not returned.
        return canonical.joined(separator: "\n")
    }

    /// The check itself: the signer is the pinned primary key, the hash covers the data and the
    /// signature's hashed part, and the RSA signature of that hash holds.
    static func verify(data: [UInt8], signature: Signature, keys: [PublicKey], fingerprint: String) throws {
        let pinned = try hexBytes(fingerprint)
        guard let key = keys.first, key.fingerprint == pinned else {
            throw Problem("the key block's primary key is not \(fingerprint)")
        }
        if let issuer = signature.issuerFingerprint, issuer != pinned {
            throw Problem("signed by \(hex(issuer)), not by \(fingerprint)")
        }
        if let keyID = signature.issuerKeyID, keyID != Array(pinned.suffix(8)) {
            throw Problem("signed by key ID \(hex(keyID)), not by \(fingerprint)")
        }
        guard signature.issuerFingerprint != nil || signature.issuerKeyID != nil else {
            throw Problem("the signature does not name its key")
        }
        guard signature.type == 0x00 || signature.type == 0x01 else {
            throw Problem("a signature of type \(signature.type), not of a document")
        }
        var trailer: [UInt8] = [0x04, 0xFF]
        let count = UInt32(signature.hashedPart.count)
        trailer += [UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
        let hashed = data + signature.hashedPart + trailer
        let digest: [UInt8]
        let algorithm: SecKeyAlgorithm
        switch signature.hashAlgorithm {
        case 8:
            digest = Array(SHA256.hash(data: hashed))
            algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 10:
            digest = Array(SHA512.hash(data: hashed))
            algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default:
            throw Problem("hash algorithm \(signature.hashAlgorithm) is not SHA-256 or SHA-512")
        }
        guard Array(digest.prefix(2)) == signature.left16 else {
            throw Problem("the data is not what was signed")
        }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(rsaPublicKeyDER(key)) as CFData, attributes as CFDictionary, &error) else {
            throw Problem("the RSA key cannot be used (\(error?.takeRetainedValue().localizedDescription ?? "unknown"))")
        }
        // An MPI drops leading zero bytes; the RSA signature is as long as the modulus.
        let length = key.modulus.count
        guard signature.value.count <= length else {
            throw Problem("the signature is longer than the key")
        }
        let padded = [UInt8](repeating: 0, count: length - signature.value.count) + signature.value
        guard SecKeyVerifySignature(secKey, algorithm, Data(digest) as CFData, Data(padded) as CFData, &error) else {
            throw Problem("the signature does not verify")
        }
    }

    static func hashName(_ algorithm: UInt8) -> String {
        switch algorithm {
        case 8: return "SHA256"
        case 10: return "SHA512"
        default: return "algorithm \(algorithm)"
        }
    }

    // MARK: Armor

    /// The bytes of the armored block "-----BEGIN PGP <kind>-----", its CRC-24 checked when given.
    static func dearmor(_ text: String, kind: String) throws -> [UInt8] {
        let lines = splitLines(text)
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "-----BEGIN PGP \(kind)-----" }) else {
            throw Problem("no PGP \(kind.lowercased()) in it")
        }
        var index = begin + 1
        // Headers ("Version: ...", "Comment: ...") until the empty line
        while index < lines.count, lines[index].contains(":"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        var body = ""
        var checksum: String?
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----END PGP \(kind)-----") {
                break
            }
            if line.hasPrefix("=") {
                checksum = String(line.dropFirst())
            } else {
                body += line
            }
            index += 1
        }
        guard index < lines.count else {
            throw Problem("the PGP \(kind.lowercased()) has no end line")
        }
        guard let data = Data(base64Encoded: body) else {
            throw Problem("the PGP \(kind.lowercased()) is not base64")
        }
        let bytes = [UInt8](data)
        if let checksum {
            guard let sum = Data(base64Encoded: checksum), sum.count == 3 else {
                throw Problem("the PGP \(kind.lowercased())'s checksum line is not 3 bytes of base64")
            }
            let crc = crc24(bytes)
            guard [UInt8]((sum)) == [UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)] else {
                throw Problem("the PGP \(kind.lowercased())'s checksum does not match")
            }
        }
        return bytes
    }

    /// The lines of `text`, each without the CR of a CR LF. Split on the LF scalar: Swift's
    /// String.split(separator: "\n") never splits a CR LF, which is one Character.
    static func splitLines(_ text: String) -> [Substring] {
        return text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            let content = line.last == "\r" ? line.dropLast() : line
            return Substring(String(String.UnicodeScalarView(content)))
        }
    }

    static func crc24(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in bytes {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 {
                    crc ^= 0x1864CFB
                }
            }
        }
        return crc & 0xFFFFFF
    }

    // MARK: Packets

    /// The packets of `bytes`: (tag, body). Partial body lengths (only literal and compressed data
    /// use them) and indeterminate old-format lengths are refused.
    static func packets(_ bytes: [UInt8]) throws -> [(tag: Int, body: [UInt8])] {
        var result: [(tag: Int, body: [UInt8])] = []
        var index = 0
        func byte(_ at: Int) throws -> Int {
            guard at < bytes.count else {
                throw Problem("a packet runs past the end")
            }
            return Int(bytes[at])
        }
        while index < bytes.count {
            let ctb = try byte(index)
            guard ctb & 0x80 != 0 else {
                throw Problem("not an OpenPGP packet")
            }
            let tag: Int
            var length: Int
            if ctb & 0x40 != 0 {
                tag = ctb & 0x3F
                let first = try byte(index + 1)
                if first < 192 {
                    length = first
                    index += 2
                } else if first < 224 {
                    length = ((first - 192) << 8) + (try byte(index + 2)) + 192
                    index += 3
                } else if first == 255 {
                    length = 0
                    for offset in 2...5 {
                        length = (length << 8) | (try byte(index + offset))
                    }
                    index += 6
                } else {
                    throw Problem("a packet with partial lengths")
                }
            } else {
                tag = (ctb >> 2) & 0x0F
                let sizes = [1, 2, 4]
                let kind = ctb & 0x03
                guard kind < 3 else {
                    throw Problem("a packet of indeterminate length")
                }
                length = 0
                for offset in 1...sizes[kind] {
                    length = (length << 8) | (try byte(index + offset))
                }
                index += 1 + sizes[kind]
            }
            guard length >= 0, index + length <= bytes.count else {
                throw Problem("a packet runs past the end")
            }
            result.append((tag, Array(bytes[index..<(index + length)])))
            index += length
        }
        return result
    }

    /// The one signature packet of a signature (tag 2).
    static func onlySignature(in bytes: [UInt8]) throws -> Signature {
        let found = try packets(bytes).filter { $0.tag == 2 }
        guard found.count == 1, let body = found.first?.body else {
            throw Problem(found.isEmpty ? "no signature packet" : "more than one signature")
        }
        return try signature(body)
    }

    static func signature(_ body: [UInt8]) throws -> Signature {
        guard body.count > 6, body[0] == 4 else {
            throw Problem("not a version 4 signature")
        }
        guard body[2] == 1 else {
            throw Problem("a signature by public key algorithm \(body[2]), not RSA")
        }
        let hashedLength = Int(body[4]) << 8 | Int(body[5])
        guard 6 + hashedLength + 2 <= body.count else {
            throw Problem("the signature's hashed part runs past its end")
        }
        let hashed = Array(body[6..<(6 + hashedLength)])
        var index = 6 + hashedLength
        let unhashedLength = Int(body[index]) << 8 | Int(body[index + 1])
        index += 2
        guard index + unhashedLength + 2 <= body.count else {
            throw Problem("the signature's unhashed part runs past its end")
        }
        let unhashed = Array(body[index..<(index + unhashedLength)])
        index += unhashedLength
        let left16 = Array(body[index..<(index + 2)])
        index += 2
        var signature = Signature(type: body[1], hashAlgorithm: body[3], hashedPart: Array(body[0..<(6 + hashedLength)]),
                                  issuerFingerprint: nil, issuerKeyID: nil, left16: left16, value: [])
        // Only the hashed part is believed for the issuer; the unhashed key ID is a hint and must
        // agree with the pinned key too (checked in verify).
        for (type, critical, data) in try subpackets(hashed) {
            switch type {
            case 2:
                break // creation time
            case 3:
                // Signature expiration: seconds after creation; 0 never
                guard data.count == 4 else {
                    throw Problem("a malformed expiration")
                }
                let seconds = data.reduce(0) { $0 << 8 | Int($1) }
                if seconds != 0 {
                    throw Problem("a signature that expires, which agent-vm does not judge")
                }
            case 16:
                signature.issuerKeyID = data
            case 33:
                guard data.count == 21, data[0] == 4 else {
                    throw Problem("an issuer fingerprint that is not a version 4 one")
                }
                signature.issuerFingerprint = Array(data.dropFirst())
            default:
                if critical {
                    throw Problem("a critical signature subpacket of type \(type), which agent-vm does not know")
                }
            }
        }
        for (type, _, data) in try subpackets(unhashed) where type == 16 && signature.issuerKeyID == nil {
            signature.issuerKeyID = data
        }
        signature.value = try mpi(body, at: &index)
        return signature
    }

    static func subpackets(_ bytes: [UInt8]) throws -> [(type: UInt8, critical: Bool, data: [UInt8])] {
        var result: [(type: UInt8, critical: Bool, data: [UInt8])] = []
        var index = 0
        while index < bytes.count {
            let first = Int(bytes[index])
            var length: Int
            if first < 192 {
                length = first
                index += 1
            } else if first < 255 {
                guard index + 1 < bytes.count else {
                    throw Problem("a subpacket runs past the end")
                }
                length = ((first - 192) << 8) + Int(bytes[index + 1]) + 192
                index += 2
            } else {
                guard index + 4 < bytes.count else {
                    throw Problem("a subpacket runs past the end")
                }
                length = 0
                for offset in 1...4 {
                    length = (length << 8) | Int(bytes[index + offset])
                }
                index += 5
            }
            guard length >= 1, index + length <= bytes.count else {
                throw Problem("a subpacket runs past the end")
            }
            let type = bytes[index]
            result.append((type & 0x7F, type & 0x80 != 0, Array(bytes[(index + 1)..<(index + length)])))
            index += length
        }
        return result
    }

    /// The RSA keys of an armored key block, the primary first, then its subkeys (tags 6 and 14).
    static func publicKeys(armored: String) throws -> [PublicKey] {
        var keys: [PublicKey] = []
        for (tag, body) in try packets(try dearmor(armored, kind: "PUBLIC KEY BLOCK")) where tag == 6 || tag == 14 {
            guard body.count > 6, body[0] == 4 else {
                throw Problem("a key that is not a version 4 one")
            }
            guard body.count < 0x10000 else {
                throw Problem("a key packet larger than 64 KB")
            }
            guard body[5] == 1 || body[5] == 3 else {
                continue // not RSA: never the pinned key here
            }
            var index = 6
            let modulus = try mpi(body, at: &index)
            let exponent = try mpi(body, at: &index)
            let header: [UInt8] = [0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
            keys.append(PublicKey(fingerprint: Array(Insecure.SHA1.hash(data: header + body)), modulus: modulus, exponent: exponent))
        }
        guard !keys.isEmpty else {
            throw Problem("no RSA key in the key block")
        }
        return keys
    }

    /// A multiprecision integer: its bit count (2 bytes), then the bytes.
    static func mpi(_ bytes: [UInt8], at index: inout Int) throws -> [UInt8] {
        guard index + 2 <= bytes.count else {
            throw Problem("a number runs past the end")
        }
        let bits = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        let count = (bits + 7) / 8
        index += 2
        guard index + count <= bytes.count else {
            throw Problem("a number runs past the end")
        }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    // MARK: Helpers

    /// PKCS #1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }, as SecKeyCreateWithData takes it.
    static func rsaPublicKeyDER(_ key: PublicKey) -> [UInt8] {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 {
                return [UInt8(count)]
            }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: [UInt8]) -> [UInt8] {
            var digits = Array(value.drop(while: { $0 == 0 }))
            if digits.isEmpty || digits[0] & 0x80 != 0 {
                digits.insert(0, at: 0)
            }
            return [0x02] + length(digits.count) + digits
        }
        let content = integer(key.modulus) + integer(key.exponent)
        return [0x30] + length(content.count) + content
    }

    static func hexBytes(_ text: String) throws -> [UInt8] {
        let digits = Array(text.replacingOccurrences(of: " ", with: "").lowercased())
        guard digits.count == 40 else {
            throw Problem("a fingerprint is 40 hexadecimal digits")
        }
        var bytes: [UInt8] = []
        var index = 0
        while index < digits.count {
            guard let value = UInt8(String(digits[index...index + 1]), radix: 16) else {
                throw Problem("a fingerprint is 40 hexadecimal digits")
            }
            bytes.append(value)
            index += 2
        }
        return bytes
    }

    static func hex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
