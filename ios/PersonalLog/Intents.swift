import AppIntents

/// The app's actions in Shortcuts, for three iOS automations (Run Immediately): Arrive at Work -> "Arrived at Work";
/// Leave Work -> "Left Work"; weekdays at 10:00 (and later times for late arrivals) -> "Office Food", then Run Shortcut
/// "Log Foods From App" with its result. Office and the office food are logged only after a 20-min stay.
struct ArrivedAtWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Arrived at Work"
    static var description = IntentDescription("Notes the arrival at Work (Office Food checks how long the stay lasted).")

    @MainActor
    func perform() async throws -> some IntentResult {
        Store.shared.arrivedAtWork()
        return .result()
    }
}

struct LeftWorkIntent: AppIntent {
    static var title: LocalizedStringResource = "Left Work"
    static var description = IntentDescription("Notes leaving Work.")

    @MainActor
    func perform() async throws -> some IntentResult {
        Store.shared.leftWork()
        return .result()
    }
}

struct OfficeFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Office Food"
    static var description = IntentDescription(
        "On a working day after a 20-min stay at Work: logs Office and returns the office food for Log Foods From App (once a day).")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = Store.shared
        await store.refresh()   // holidays and recipes, when online
        let input = store.officeFood()
        await store.flush()
        return .result(value: input)
    }
}
