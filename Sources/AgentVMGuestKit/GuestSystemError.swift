// Sources/AgentVMGuestKit/GuestSystemError.swift
//
// A system call that failed in code the guest daemon and the host share. Its text is the one
// the host's own errors use for a failed system call.

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

package struct GuestSystemError: Error, Equatable, CustomStringConvertible {
    package var operation: String
    package var code: Int32

    package init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    package var description: String {
        return Printable.lines("\(operation) failed: \(String(cString: strerror(code))) (errno \(code))", limit: 8000)
    }
}
