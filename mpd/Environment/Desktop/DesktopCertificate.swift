// mpd-desktop certificate trust integration

#if os(macOS)
import Foundation

extension Mpd.Environment.Certificate {
    static func trustCA(caPath: String) {
        let isTrusted = {
            Mpd.Environment.HostExec.capture(["security", "verify-cert", "-c", caPath],
                    suppressStderr: true).0 == 0
        }
        if isTrusted() {
            ok("CA already trusted in macOS Keychain.");
            return
        }

        let deleteCmd = "sudo security delete-certificate -c \"mpd.test local development CA\" /Library/Keychains/System.keychain 2>/dev/null; true"
        let addCmd = "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(caPath)"
        print("""

          ACTION REQUIRED — Trust the mpd CA (requires sudo + Keychain approval):

          Step 1 — Remove old CA (safe to skip on first install):
            \(deleteCmd)

          Step 2 — Add and trust the new CA:
            \(addCmd)

          After entering your sudo password, macOS will prompt you to approve
          the Keychain change with Touch ID or your login password.

        """)

        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var rawTermios = oldTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios) }

        while true {
            if isTrusted() {
                ok("CA is trusted in macOS Keychain.");
                return
            }

            print("")
            print("  CA not yet trusted.")
            print("    1. Retry  [Enter]")
            print("    2. Copy delete command to clipboard")
            print("    3. Copy add command to clipboard")
            print("  Choice: ", terminator: "")
            fflush(stdout)

            var key: String? = nil
            while key == nil {
                var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 2000) > 0 {
                    var buf = [UInt8](repeating: 0, count: 1)
                    if read(STDIN_FILENO, &buf, 1) == 1 {
                        key = String(UnicodeScalar(buf[0]))
                    }
                } else if isTrusted() {
                    print("\n  CA trusted!")
                    ok("CA is trusted in macOS Keychain.")
                    return
                }
            }

            print(key!)
            switch key! {
            case "2":
                let rc = Mpd.Environment.HostExec.run(["pbcopy"], input: Data(deleteCmd.utf8))
                if rc == 0 {
                    print("  Delete command copied to clipboard.")
                } else {
                    print("  Clipboard copy failed. Delete command:")
                    print(deleteCmd)
                }
            case "3":
                let rc = Mpd.Environment.HostExec.run(["pbcopy"], input: Data(addCmd.utf8))
                if rc == 0 {
                    print("  Add command copied to clipboard.")
                } else {
                    print("  Clipboard copy failed. Add command:")
                    print(addCmd)
                }
            default:
                break
            }
        }
    }

}
#endif
