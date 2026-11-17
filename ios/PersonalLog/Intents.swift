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

/// Food queued for MacroFactor from elsewhere (the watch, Muse; public.app_food_queue_*), for the Shortcut run by the
/// automation "When I receive a notification from Home Assistant, title contains Log food" (Run Immediately):
/// Take Queued Food -> if it has a value: Run Shortcut "Log Foods From App" with it -> Mark Queued Food Logged.
/// Take returns every open item as one input of Log Foods From App ("" when there's nothing) and remembers their ids
/// for Mark; an item never marked is pushed again after 10 min.
struct TakeQueuedFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Take Queued Food"
    static var description = IntentDescription("Everything queued for MacroFactor, as the input of Log Foods From App (empty when none).")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let creds = Store.shared.creds
        guard creds.isComplete else { return .result(value: "") }
        let data = try await API(creds: creds).rpc("app_food_queue_take", json: [:])
        let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let ids = r["ids"] as? [NSNumber], let input = r["input"],
              let json = try? JSONSerialization.data(withJSONObject: input),
              let text = String(data: json, encoding: .utf8) else { return .result(value: "") }
        UserDefaults.standard.set(ids.map(\.int64Value), forKey: "foodQueueTaken")
        return .result(value: text)
    }
}

struct MarkQueuedFoodLoggedIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Queued Food Logged"
    static var description = IntentDescription("Marks what Take Queued Food returned as logged in MacroFactor.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let ids = (UserDefaults.standard.array(forKey: "foodQueueTaken") as? [Int64]) ?? []
        guard !ids.isEmpty, Store.shared.creds.isComplete else { return .result() }
        _ = try await API(creds: Store.shared.creds).rpc("app_food_queue_done", json: ["p_ids": ids])
        UserDefaults.standard.removeObject(forKey: "foodQueueTaken")
        return .result()
    }
}

/// One event through the app's own queue (sent now, or when back online): for the app open / close and place
/// automations, in place of a Shortcut keeping its own queue file. Kind log, or a session's start / end.
struct LogEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Event"
    static var description = IntentDescription("Logs an event to the database through the app's queue (sent when online).")

    @Parameter(title: "Name") var name: String
    @Parameter(title: "Kind", default: .log) var kind: EventKind

    @MainActor
    func perform() async throws -> some IntentResult {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return .result() }
        let store = Store.shared
        store.enqueue(OutEvent(name: n, kind: kind.rawValue, at: Date()))
        await store.flush()
        await Chores.shared.refreshIfStale()   // keeps the shared Chores list current (every 15 min at most)
        return .result()
    }
}

enum EventKind: String, AppEnum {
    case log, start, end

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Kind"
    static var caseDisplayRepresentations: [EventKind: DisplayRepresentation] = [.log: "Log", .start: "Start", .end: "End"]
}
