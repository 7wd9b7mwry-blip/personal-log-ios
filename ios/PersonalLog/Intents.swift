import AppIntents

/// The app's actions in Shortcuts. "Arrived at Work" is for an iOS automation on arriving at Work (Run Immediately),
/// followed by Run Shortcut "Log Foods From App" with its result: logs Office and the office food on working days.
struct ArrivedAtWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Arrived at Work"
    static var description = IntentDescription(
        "Logs Office and returns the office food for Log Foods From App (weekdays that aren't holidays, food once a day).")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = Store.shared
        await store.refresh()   // holidays and recipes, when online
        let input = store.arrivedAtWork()
        await store.flush()
        return .result(value: input)
    }
}
