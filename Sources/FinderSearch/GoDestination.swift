import SwiftUI

enum GoDestination: String, CaseIterable, Identifiable {
    case recents, documents, desktop, downloads, home, library, applications, utilities
    var id: Self { self }
    var title: String {
        switch self {
        case .recents: L10n.string("Recents")
        case .documents: L10n.string("Documents")
        case .desktop: L10n.string("Desktop")
        case .downloads: L10n.string("Downloads")
        case .home: L10n.string("Home")
        case .library: L10n.string("Library")
        case .applications: L10n.string("Applications")
        case .utilities: L10n.string("Utilities")
        }
    }
    var key: Character {
        switch self {
        case .recents: "f"
        case .documents: "o"
        case .desktop: "d"
        case .downloads, .library: "l"
        case .home: "h"
        case .applications: "a"
        case .utilities: "u"
        }
    }
    var modifiers: EventModifiers {
        self == .downloads ? [.command, .option] : [.command, .shift]
    }
    var route: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .recents: return "recents"
        case .documents: return home + "/Documents"
        case .desktop: return home + "/Desktop"
        case .downloads: return home + "/Downloads"
        case .home: return home
        case .library: return home + "/Library"
        case .applications: return "/Applications"
        case .utilities: return "/Applications/Utilities"
        }
    }
}
