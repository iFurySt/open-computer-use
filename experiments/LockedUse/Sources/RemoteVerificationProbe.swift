import Foundation
import Security
import CoreGraphics

// Isolated non-locking diagnostic. No lease is created or permit requested.
// Uses only the existing remote right while normally unlocked. It never
// installs a right or requests system.login.screensaver.
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      session[kCGSessionOnConsoleKey as String] as? Bool == true,
      session[kCGSessionLoginDoneKey as String] as? Bool == true,
      (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == getuid(),
      session["CGSSessionScreenIsLocked"] == nil || session["CGSSessionScreenIsLocked"] as? Bool == false else { exit(2) }
var installed: CFDictionary?
guard AuthorizationRightGet("dev.opencomputeruse.locked-use.remote", &installed) == errAuthorizationSuccess,
      let rule = installed as? [String: Any],
      rule["class"] as? String == "evaluate-mechanisms",
      rule["mechanisms"] as? [String] == ["OCULockAuth:remote,privileged"],
      (rule["shared"] as? NSNumber)?.boolValue == false else { exit(2) }
var reference: AuthorizationRef?
let created = AuthorizationCreate(nil, nil, [], &reference)
guard created == errAuthorizationSuccess, let reference else { exit(2) }
defer { AuthorizationFree(reference, [.destroyRights]) }
let began = ProcessInfo.processInfo.systemUptime
let status = "dev.opencomputeruse.locked-use.remote".withCString { name in
    var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
    return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        return AuthorizationCopyRights(reference, &rights, nil, [.extendRights, .destroyRights], nil)
    }
}
let result: [String: Any] = ["event": "remoteVerificationProbe", "status": status,
    "expectedDenied": status == errAuthorizationDenied, "sessionLockRequested": false,
    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
exit(status == errAuthorizationDenied ? 0 : 1)
