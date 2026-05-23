// In-VM host command execution adapter

import Foundation

extension Mpd.VM {
    private static let binaryPaths: [String: String] = [
        "podman": "/usr/bin/podman",
        "sudo": "/usr/bin/sudo",
        "openssl": "/usr/bin/openssl",
        "bash": "/bin/bash",
        "cp": "/bin/cp",
        "rm": "/usr/bin/rm",
        "install": "/usr/bin/install",
        "whoami": "/usr/bin/whoami",
        "id": "/usr/bin/id",
        "git": "/usr/bin/git",
        "ping": "/usr/bin/ping",
        "sha256sum": "/usr/bin/sha256sum",
        "update-ca-certificates": "/usr/sbin/update-ca-certificates",
        "systemctl": "/usr/bin/systemctl",
        "ip": "/usr/sbin/ip",
        "ssh-keygen": "/usr/bin/ssh-keygen",
        "certutil": "/usr/bin/certutil",
    ]

    static func binaryPath(for name: String) -> String? {
        return binaryPaths[name]
    }

    static func requiredBinaryNames() -> [String] {
        return binaryPaths.keys.sorted()
    }

    static func require(_ name: String) -> String {
        guard let path = binaryPaths[name] else {
            fatalError("Binary path missing for '\(name)'")
        }
        if (!FileManager.default.isExecutableFile(atPath: path)) {
            fatalError("Binary path is not executable '\(path)'")
        }
        return path
    }

    static func isExecutable(_ name: String) -> Bool {
        let path = binaryPaths[name] ?? "";
        if (path == "") {
            return false;
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    @discardableResult
    static func exec(_ args: [String], input: Data? = nil, useSudo: Bool = false) -> Int32 {
        guard let command = args.first else {
            errPrint("Command not found or not executable: \(args.first ?? "(empty)")")
            return 127
        }
        guard let resolvedCommand = binaryPaths[command] else {
            return 127
        }

        let p = Process()

        if useSudo {
            let sudoPath = Mpd.VM.require("sudo")
            p.executableURL = URL(fileURLWithPath: sudoPath)
            p.arguments = ["-n", resolvedCommand] + Array(args.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: resolvedCommand)
            p.arguments = Array(args.dropFirst())
        }

        if (input == nil) {
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                errPrint("Failed to launch \(command): \(error)")
                return 1
            }
        } else {
            let stdin = Pipe()
            p.standardInput = stdin
            do {
                try p.run()
            } catch {
                errPrint("Failed to launch \(command): \(error)")
                return 1
            }
            stdin.fileHandleForWriting.write(input!)
            stdin.fileHandleForWriting.closeFile()
        }

        p.waitUntilExit()
        return p.terminationStatus
    }

    static func capture(_ args: [String], suppressStderr: Bool = false, useSudo: Bool = false) -> (Int32, String) {
        guard let command = args.first else {
            errPrint("Command not found or not executable: \(args.first ?? "(empty)")")
            return (127, "")
        }
        guard let resolvedCommand = binaryPaths[command] else {
            return (127, "")
        }

        let p = Process()
        if useSudo {
            let sudoPath = Mpd.VM.require("sudo")
            p.executableURL = URL(fileURLWithPath: sudoPath)
            p.arguments = ["-n", resolvedCommand] + Array(args.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: resolvedCommand)
            p.arguments = Array(args.dropFirst())
        }
        p.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = suppressStderr
            ? (FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice)
            : FileHandle.standardError

        do { try p.run() } catch {
            errPrint("Failed to launch \(command): \(error)")
            return (1, "")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        return (
            p.terminationStatus,
            String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
