import SwiftUI

/// One condition (routine.cond): a sensor reading, a room, a time window, weekdays, an event logged or not logged,
/// another chore done, a weigh-in, the morning photos; or its opposite. A nested group the AI wrote, which the
/// editor can't show, is kept as its JSON (kind "raw").
struct CondLeaf: Identifiable, Hashable {
    var id = UUID()
    var kind = "sensor"     // sensor | room | time | weekday | event | no_event | chore | weight | photos | raw
    var negate = false
    var entity = ""
    var op = ">"            // < > = !=
    var value = ""
    var minutes = 0         // sensor / room: held this long; event: in the last N min (0 = today); no_event: for
    var room = ""
    var after = ""
    var before = ""
    var weekdays: [Int] = []
    var name = ""           // event / no_event (comma separated) / chore
    var raw = ""

    static let kinds: [(String, String)] = [
        ("sensor", "A sensor reading"), ("room", "I'm in a room"), ("time", "Time of day"), ("weekday", "Weekdays"),
        ("event", "An event was logged"), ("no_event", "Nothing logged for a while"), ("chore", "Another chore is done"),
        ("weight", "I weighed in"), ("photos", "The morning photos are taken"),
    ]

    init() {}

    init(_ any: Any) {
        guard var j = any as? [String: Any] else {
            kind = "raw"
            raw = CondLeaf.text(any)
            return
        }
        if j.count == 1, let inner = j["not"] as? [String: Any] {
            negate = true
            j = inner
        }
        if let e = j["entity"] as? String, let o = j["op"] as? String, ["<", ">", "=", "!="].contains(o) {
            kind = "sensor"; entity = e; op = o; value = CondLeaf.text(j["value"] ?? "")
            minutes = (j["for_minutes"] as? NSNumber)?.intValue ?? 0
        } else if let r = j["room"] as? String {
            kind = "room"; room = r; minutes = (j["for_minutes"] as? NSNumber)?.intValue ?? 0
        } else if let t = j["time"] as? [String: Any] {
            kind = "time"; after = t["after"] as? String ?? ""; before = t["before"] as? String ?? ""
        } else if let w = j["weekday"] as? [NSNumber] {
            kind = "weekday"; weekdays = w.map(\.intValue)
        } else if let n = j["event"] as? String, j["op"] == nil {
            kind = "event"; name = n; minutes = (j["within_minutes"] as? NSNumber)?.intValue ?? 0
        } else if j["no_event"] != nil {
            kind = "no_event"
            name = (j["no_event"] as? String) ?? ((j["no_event"] as? [String])?.joined(separator: ", ") ?? "")
            minutes = (j["minutes"] as? NSNumber)?.intValue ?? 60
        } else if let n = j["chore_done"] as? String {
            kind = "chore"; name = n
        } else if j["weight"] as? Bool == true {
            kind = "weight"
        } else if j["photos"] != nil {
            kind = "photos"
        } else {
            kind = "raw"; negate = false; raw = CondLeaf.text(any)
        }
    }

    static func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return Fmt.amount(n.doubleValue) }
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    var isComplete: Bool {
        switch kind {
        case "sensor": return !entity.isEmpty && !value.trimmingCharacters(in: .whitespaces).isEmpty
            && (op == "=" || op == "!=" || Double(value) != nil)
        case "room": return !room.isEmpty
        case "time": return !after.isEmpty || !before.isEmpty
        case "weekday": return !weekdays.isEmpty
        case "event", "chore": return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case "no_event": return !name.trimmingCharacters(in: .whitespaces).isEmpty && minutes > 0
        default: return true
        }
    }

    var json: Any {
        var j: [String: Any]
        switch kind {
        case "sensor":
            j = ["entity": entity, "op": op]
            if op == "<" || op == ">", let n = Double(value) { j["value"] = n } else { j["value"] = value.trimmingCharacters(in: .whitespaces) }
            if minutes > 0 { j["for_minutes"] = minutes }
        case "room":
            j = ["room": room]
            if minutes > 0 { j["for_minutes"] = minutes }
        case "time":
            var t: [String: Any] = [:]
            if !after.isEmpty { t["after"] = after }
            if !before.isEmpty { t["before"] = before }
            j = ["time": t]
        case "weekday": j = ["weekday": weekdays.sorted()]
        case "event":
            j = ["event": name.trimmingCharacters(in: .whitespaces)]
            if minutes > 0 { j["within_minutes"] = minutes }
        case "no_event":
            j = ["no_event": name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                 "minutes": max(minutes, 1)]
        case "chore": j = ["chore_done": name]
        case "weight": j = ["weight": true]
        case "photos": j = ["photos": ["Face", "Left Hand", "Right Hand"]]
        default: return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? NSNull()
        }
        return negate ? ["not": j] : j
    }

    func summary(_ sensors: [SensorInfo]) -> String {
        let held = minutes > 0 ? " for \(minutes) min" : ""
        let s: String
        switch kind {
        case "sensor":
            let who = sensors.first { $0.entity == entity }?.name ?? entity
            let word = ["<": "below", ">": "above", "=": "is", "!=": "is not"][op] ?? op
            s = entity.isEmpty ? "Choose a sensor" : "\(who) \(word) \(value)\(held)"
        case "room": s = room.isEmpty ? "Choose a room" : "I'm in the \(room)\(held)"
        case "time":
            let parts = [after.isEmpty ? nil : "after \(after)", before.isEmpty ? nil : "before \(before)"].compactMap { $0 }
            s = parts.isEmpty ? "Set a time" : parts.joined(separator: " and ")
        case "weekday":
            let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            s = weekdays.isEmpty ? "Choose days" : "on " + weekdays.sorted().map { names[$0] }.joined(separator: ", ")
        case "event": s = name.isEmpty ? "Name the event" : "\(name) logged" + (minutes > 0 ? " in the last \(minutes) min" : " today")
        case "no_event": s = name.isEmpty ? "Name the events" : "no \(name) for \(minutes) min"
        case "chore": s = name.isEmpty ? "Choose a chore" : "\(name) is done"
        case "weight": s = "weighed in"
        case "photos": s = "morning photos taken"
        default: s = "(set by the AI) " + raw
        }
        return negate ? "not: " + s : s
    }
}

/// Conditions matched all together or any one of them (a single one is just that condition).
struct ChoreCondition: Hashable {
    var any = false
    var leaves: [CondLeaf] = []

    init() {}

    init?(_ j: Any?) {
        guard let d = j as? [String: Any] else { return nil }
        if d.count == 1, let a = d["all"] as? [Any] {
            leaves = a.map { CondLeaf($0) }
        } else if d.count == 1, let a = d["any"] as? [Any] {
            any = true
            leaves = a.map { CondLeaf($0) }
        } else {
            leaves = [CondLeaf(d)]
        }
    }

    var isComplete: Bool { !leaves.isEmpty && leaves.allSatisfy(\.isComplete) }

    var json: Any { leaves.count == 1 ? leaves[0].json : [any ? "any" : "all": leaves.map(\.json)] }

    func summary(_ sensors: [SensorInfo]) -> String {
        leaves.map { $0.summary(sensors) }.joined(separator: any ? " or " : " and ")
    }
}

/// A chore part's conditions in a form: each one a row (tap to edit, swipe to remove), "all" / "any" when there are
/// several, and an add button. nil when there are none.
struct ConditionEditor: View {
    @ObservedObject private var chores = Chores.shared
    @Binding var cond: ChoreCondition?

    private var c: Binding<ChoreCondition> {
        Binding(get: { cond ?? ChoreCondition() }, set: { cond = $0.leaves.isEmpty ? nil : $0 })
    }

    var body: some View {
        if c.wrappedValue.leaves.count > 1 {
            Picker("Match", selection: c.any) {
                Text("all of these").tag(false)
                Text("any of these").tag(true)
            }
        }
        ForEach(c.leaves) { $leaf in
            NavigationLink {
                LeafEditor(leaf: $leaf)
            } label: {
                Text(leaf.summary(chores.sensors)).foregroundStyle(leaf.isComplete ? Color.primary : Color.orange)
            }
        }
        .onDelete { c.wrappedValue.leaves.remove(atOffsets: $0) }
        Button {
            c.wrappedValue.leaves.append(CondLeaf())
        } label: {
            Label(c.wrappedValue.leaves.isEmpty ? "Add a condition" : "Add another", systemImage: "plus.circle")
        }
    }
}

/// One condition's settings.
struct LeafEditor: View {
    @ObservedObject private var chores = Chores.shared
    @Binding var leaf: CondLeaf

    private let weekdayNames = [(1, "M"), (2, "T"), (3, "W"), (4, "T"), (5, "F"), (6, "S"), (7, "S")]

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $leaf.kind) {
                    ForEach(CondLeaf.kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                    if leaf.kind == "raw" { Text("Set by the AI").tag("raw") }
                }
                Toggle("The opposite (not)", isOn: $leaf.negate)
            }
            Section { fields }
        }
        .navigationTitle("Condition")
        .navigationBarTitleDisplayMode(.inline)
        .task { await chores.loadSensors() }
    }

    @ViewBuilder
    private var fields: some View {
        switch leaf.kind {
        case "sensor":
            let sensor = chores.sensors.first { $0.entity == leaf.entity }
            let numeric = sensor?.numeric ?? (leaf.op == "<" || leaf.op == ">")
            NavigationLink {
                SensorPicker { s in
                    leaf.entity = s.entity
                    if s.numeric {
                        if leaf.op == "=" || leaf.op == "!=" { leaf.op = ">" }
                    } else {
                        if leaf.op == "<" || leaf.op == ">" { leaf.op = "=" }
                        if leaf.value.isEmpty { leaf.value = s.state }
                    }
                }
            } label: {
                LabeledContent("Sensor") {
                    Text(sensor.map { "\($0.name) · \($0.reading)" } ?? (leaf.entity.isEmpty ? "Choose" : leaf.entity)).lineLimit(2)
                }
            }
            Picker("When it is", selection: $leaf.op) {
                if numeric {
                    Text("above").tag(">")
                    Text("below").tag("<")
                }
                Text("exactly").tag("=")
                Text("not").tag("!=")
            }
            TextField(numeric ? "Value" : "State (e.g. on, off, full)", text: $leaf.value)
                .keyboardType(numeric ? .decimalPad : .default).textInputAutocapitalization(.never)
            held
        case "room":
            Picker("Room", selection: $leaf.room) {
                Text("Choose").tag("")
                ForEach(Array(Set(chores.rooms + ["kitchen", "bathroom", "bedroom", "living room", "office"])).sorted(), id: \.self) { r in
                    Text(r).tag(r)
                }
            }
            held
        case "time":
            Toggle("After", isOn: Binding(get: { !leaf.after.isEmpty }, set: { leaf.after = $0 ? "18:00" : "" }))
            if !leaf.after.isEmpty {
                DatePicker("After", selection: clock($leaf.after), displayedComponents: .hourAndMinute)
            }
            Toggle("Before", isOn: Binding(get: { !leaf.before.isEmpty }, set: { leaf.before = $0 ? "23:00" : "" }))
            if !leaf.before.isEmpty {
                DatePicker("Before", selection: clock($leaf.before), displayedComponents: .hourAndMinute)
            }
        case "weekday":
            HStack {
                ForEach(weekdayNames, id: \.0) { d in
                    let on = leaf.weekdays.contains(d.0)
                    Button(d.1) {
                        if on { leaf.weekdays.removeAll { $0 == d.0 } } else { leaf.weekdays.append(d.0) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(on ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .buttonStyle(.plain)
                }
            }
        case "event":
            TextField("Event name (e.g. Night Supplements, Shower)", text: $leaf.name)
            Stepper(leaf.minutes == 0 ? "Any time today" : "In the last \(leaf.minutes) min", value: $leaf.minutes, in: 0...720, step: 15)
        case "no_event":
            TextField("Event names, comma separated", text: $leaf.name)
            Stepper("For \(leaf.minutes) min", value: $leaf.minutes, in: 5...720, step: 15)
        case "chore":
            Picker("Chore", selection: $leaf.name) {
                Text("Choose").tag("")
                ForEach(chores.chores.map(\.name).sorted(), id: \.self) { n in Text(n).tag(n) }
            }
        case "raw":
            Text(leaf.raw).font(.caption.monospaced())
            Text("Ask the AI to change this one, or pick a kind above to replace it.").font(.footnote).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var held: some View {
        Stepper(leaf.minutes == 0 ? "Right away" : "Held for \(leaf.minutes) min", value: $leaf.minutes, in: 0...240, step: 5)
    }

    private func clock(_ s: Binding<String>) -> Binding<Date> {
        Binding(get: { ChoreTime.clock(s.wrappedValue) }, set: { s.wrappedValue = ChoreTime.hhmm($0) })
    }
}
