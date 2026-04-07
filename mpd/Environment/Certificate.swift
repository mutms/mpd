// mpd — shared certificate operations
// OpenSSL-backed CA and leaf cert generation used by environment integrations.

import Foundation

extension Mpd.Environment.Certificate {

    static func generateCA(caKeyPath: String, caCertPath: String, certsDir: String) throws {
        let caConf = "\(certsDir)/mpd-ca.conf"
        let caConfContent = """
            [ req ]
            distinguished_name = req_dn
            x509_extensions    = v3_ca
            prompt             = no

            [ req_dn ]
            O  = mpd.test local development CA
            CN = mpd.test local development CA

            [ v3_ca ]
            basicConstraints       = critical, CA:TRUE, pathlen:0
            subjectKeyIdentifier   = hash
            keyUsage               = critical, keyCertSign, cRLSign
            nameConstraints        = critical, @name_constraints

            [ name_constraints ]
            permitted;DNS.0        = .mpd.test
            permitted;DNS.1        = mpd.test
            """
        try caConfContent.write(toFile: caConf, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: caConf) }

        guard Mpd.Environment.HostExec.run(["openssl", "genrsa", "-out", caKeyPath, "4096"]) == 0,
              Mpd.Environment.HostExec.run(["openssl", "req", "-new", "-x509",
                     "-key", caKeyPath, "-out", caCertPath,
                     "-days", "3650", "-config", caConf]) == 0
        else { throw RuntimeError("Failed to generate CA certificate.") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKeyPath)
    }

    static func generateCert(
        sans: [String],
        certPath: String,
        keyPath: String,
        caKeyPath: String,
        caCertPath: String,
        certsDir: String
    ) throws {
        let csr = "\(certsDir)/tmp.csr"
        let extFile = "\(certsDir)/tmp.ext"
        let cn = sans.first ?? "mpd.test"
        let sanList = sans.map { "DNS:\($0)" }.joined(separator: ", ")

        let extContent = """
            authorityKeyIdentifier=keyid,issuer
            basicConstraints=CA:FALSE
            keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
            subjectAltName = \(sanList)
            """
        try extContent.write(toFile: extFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: csr)
            try? FileManager.default.removeItem(atPath: extFile)
        }

        guard Mpd.Environment.HostExec.run(["openssl", "genrsa", "-out", keyPath, "2048"]) == 0,
              Mpd.Environment.HostExec.run(["openssl", "req", "-new", "-key", keyPath, "-out", csr,
                     "-subj", "/CN=\(cn)"]) == 0,
              Mpd.Environment.HostExec.run(["openssl", "x509", "-req",
                     "-in", csr, "-CA", caCertPath, "-CAkey", caKeyPath,
                     "-CAcreateserial", "-out", certPath,
                     "-days", "397", "-extfile", extFile]) == 0
        else { throw RuntimeError("Failed to generate certificate for \(cn).") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    }
}
