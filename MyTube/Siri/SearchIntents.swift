import AppIntents

/// "Search MyTube for Dune": Siri passes the spoken term straight through.
@AppIntent(schema: .system.search)
struct SearchYouTubeIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        SearchModel.shared.search(criteria.term)
        return .result()
    }
}

/// "Search with MyTube": Siri asks what to search for, since shortcut phrases can't carry free text.
struct AskAndSearchYouTubeIntent: AppIntent {
    static let title: LocalizedStringResource = "Search YouTube"
    static let description = IntentDescription("Searches YouTube and shows the results in MyTube.")
    static let openAppWhenRun = true

    @Parameter(title: "Search Term", requestValueDialog: "What do you want to search for?")
    var term: String

    @MainActor
    func perform() async throws -> some IntentResult {
        SearchModel.shared.search(term)
        return .result()
    }
}

struct MyTubeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAndSearchYouTubeIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Search \(.applicationName)",
                "Search YouTube with \(.applicationName)",
                "Search for something with \(.applicationName)",
                "Find something with \(.applicationName)",
            ],
            shortTitle: "Search YouTube",
            systemImageName: "magnifyingglass"
        )
    }
}
