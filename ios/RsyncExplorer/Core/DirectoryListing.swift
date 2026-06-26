import Foundation

/// A folder listed across every snapshot root, plus whether the read was authoritative.
///
/// `complete == false` means at least one snapshot couldn't be read for a reason that
/// ISN'T "it legitimately doesn't have this folder" — a dropped connection, or an I/O
/// error on a still-rebuilding array. The caller may show such a result, but must NOT
/// cache it, so a transient hiccup can't get baked in as the truth (the classic symptom
/// being "only the latest snapshot shows" until a manual refresh).
struct LoadedListing: Equatable {
    let listings: [[RemoteEntry]]   // per root, newest -> oldest
    let complete: Bool
}

/// Outcome of listing ONE snapshot's copy of a folder — distinguishes a definitive
/// "not there" from "couldn't read", which look identical once collapsed to an empty list.
enum DirectoryReadOutcome: Equatable {
    case listed([RemoteEntry])   // the read succeeded (possibly an empty folder)
    case absent                  // the server definitively answered "not there" (folder created later, permission)
    case failed                  // we couldn't read it (connection/IO) — don't trust the absence
}
