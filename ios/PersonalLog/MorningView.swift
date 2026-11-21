import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import UIKit

/// The morning routine's settings (analysis.setting.routine.morning, public.app_morning): wake times and the alarm
/// chain, plus whether today's photos are done.
struct MorningSettings: Equatable {
    var weekday = "07:30"
    var weekend = "09:00"
    var alarmOn = true
    var afterMinutes = 2        // the first alarm this long after the wake-up (the bed, blinds and lights go first)
    var everyMinutes = 5
    var count = 6
    var photosDoneToday = false
    var wakes: [Date] = []          // the next seven mornings' wake times, from Home Assistant's wake-up schedule
    var alarmFrom: [Date] = []      // where each morning's alarms count from: the wake-up, or the latest the smart wake may ring
    var fromHomeAssistant = false

    init() {}

    init(_ j: [String: Any]) {
        weekday = j["weekday"] as? String ?? "07:30"
        weekend = j["weekend"] as? String ?? "09:00"
        let a = j["alarm"] as? [String: Any] ?? [:]
        alarmOn = a["on"] as? Bool ?? true
        afterMinutes = (a["after_minutes"] as? NSNumber)?.intValue ?? 2
        everyMinutes = (a["every_minutes"] as? NSNumber)?.intValue ?? 5
        count = (a["count"] as? NSNumber)?.intValue ?? 6
        photosDoneToday = j["photos_done_today"] as? Bool ?? false
        let ws = (j["wakes"] as? [[String: Any]]) ?? []
        wakes = ws.compactMap { ($0["at"] as? String).flatMap(ChoreTime.instant) }
        alarmFrom = ws.compactMap { (($0["alarm_from"] ?? $0["at"]) as? String).flatMap(ChoreTime.instant) }
        fromHomeAssistant = j["source"] as? String == "home_assistant"
    }

    /// "Tue 8:00 AM, Wed 8:00 AM"
    var upcoming: String {
        wakes.filter { $0 > Date() }.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }.joined(separator: ", ")
    }

    var payload: [String: Any] {
        ["weekday": weekday, "weekend": weekend, "alarm": ["on": alarmOn, "after_minutes": afterMinutes, "every_minutes": everyMinutes, "count": count]]
    }

    /// The wake time on a day (holidays from the app settings count as weekend).
    func wake(on day: Date, holidays: [String]) -> Date? {
        let weekendDay = Calendar.current.isDateInWeekend(day) || holidays.contains(ChoreTime.dayString(day))
        let p = (weekendDay ? weekend : weekday).split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: day)
    }
}

/// The wake alarm, Wayk style: an alarm `afterMinutes` after the wake time (the Eight Sleep, blinds and lights start at
/// it) and another every `everyMinutes`, `count` in all, for the next seven days (refreshed in the background too, so
/// it keeps going without the app opened). Stopping one only waits for the next; the chain is cancelled the moment the
/// first morning photo is taken (on the phone, before it is sent: a slow server never keeps the alarm going). Alarms
/// are AlarmKit's (iOS 26), so they ring through silent mode and Focus. "I'm up" on the alarm stops the Eight Sleep
/// alarm at once and opens the photos; "Snooze" waits for the next alarm; "Can't today" in the photos is the way out.
@MainActor
enum MorningAlarms {
    private static let key = "morningAlarms"   // [ISO date: alarm UUID]
    private static let stoppedKey = "morningAlarmsStopped"   // the day the photos stopped them (yyyy-MM-dd)

    /// Today's alarms were stopped by a photo (or "Can't today"): sync doesn't put them back before the server knows.
    static var stoppedToday: Bool { UserDefaults.standard.string(forKey: stoppedKey) == dayKey(Date()) }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func sync(_ m: MorningSettings) async {
        guard #available(iOS 26.0, *) else { return }
        var scheduled = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        var wanted: [String: Date] = [:]
        if m.alarmOn, await authorized() {
            let holidays = Store.shared.config.holidays
            for offset in 0..<7 {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { continue }
                if offset == 0 && (m.photosDoneToday || stoppedToday) { continue }
                // Home Assistant's wake-up schedule when the server sent it (from the latest the smart wake may still
                // ring that morning), else the app's own times
                let fromServer = m.alarmFrom.first { Calendar.current.isDate($0, inSameDayAs: day) }
                guard let wake = fromServer ?? m.wake(on: day, holidays: holidays) else { continue }
                for i in 0..<max(1, m.count) {
                    let at = wake.addingTimeInterval(Double(max(0, m.afterMinutes) * 60 + i * max(1, m.everyMinutes) * 60))
                    if at > Date().addingTimeInterval(30) { wanted[Fmt.iso(at)] = at }
                }
            }
        }
        for (k, id) in scheduled where wanted[k] == nil {
            if let u = UUID(uuidString: id) { try? AlarmManager.shared.cancel(id: u) }
            scheduled[k] = nil
        }
        for (k, at) in wanted where scheduled[k] == nil {
            if let id = await schedule(at) { scheduled[k] = id.uuidString }
        }
        UserDefaults.standard.set(scheduled, forKey: key)
    }

    /// The Eight Sleep alarm off now (public.app_home_action -> the add-on presses its dismiss button).
    static func stopBed() async {
        let creds = Store.shared.creds
        guard creds.isComplete else { return }
        _ = try? await API(creds: creds).rpc("app_home_action", json: ["p_action": "bed_alarm_stop"])
    }

    /// A morning photo is in: the ringing alarm and the rest of today's go, on the phone, no network. Also any of the
    /// app's alarms ringing now or due today that the list lost track of.
    static func cancelToday() {
        UserDefaults.standard.set(dayKey(Date()), forKey: stoppedKey)
        guard #available(iOS 26.0, *) else { return }
        let endOfDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        if let all = try? AlarmManager.shared.alarms {
            for a in all {
                var today = a.state == .alerting
                if case .fixed(let at)? = a.schedule, at < endOfDay { today = true }
                if today {
                    try? AlarmManager.shared.stop(id: a.id)
                    try? AlarmManager.shared.cancel(id: a.id)
                }
            }
        }
        var scheduled = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        for (k, id) in scheduled {
            guard let at = ChoreTime.instant(k), at < end else { continue }
            if let u = UUID(uuidString: id) {
                try? AlarmManager.shared.stop(id: u)
                try? AlarmManager.shared.cancel(id: u)
            }
            scheduled[k] = nil
        }
        UserDefaults.standard.set(scheduled, forKey: key)
    }

    @available(iOS 26.0, *)
    private static func authorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .notDetermined: return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default: return false
        }
    }

    @available(iOS 26.0, *)
    private static func schedule(_ at: Date) async -> UUID? {
        let alert = AlarmPresentation.Alert(
            title: "Wake up",
            stopButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
            secondaryButton: AlarmButton(text: "I'm up", textColor: .white, systemImageName: "camera.fill"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes<MorningAlarmData>(presentation: AlarmPresentation(alert: alert),
                                                          metadata: MorningAlarmData(), tintColor: .orange)
        let config = AlarmManager.AlarmConfiguration<MorningAlarmData>(
            countdownDuration: nil, schedule: .fixed(at), attributes: attributes,
            stopIntent: nil, secondaryIntent: OpenMorningPhotosIntent(), sound: .default)
        let id = UUID()
        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
            return id
        } catch {
            return nil
        }
    }
}

@available(iOS 26.0, *)
struct MorningAlarmData: AlarmMetadata {}

/// The alarm's "I'm up" button: stops the Eight Sleep alarm (the add-on, within ~10 s) and opens the app on the photo
/// steps. The phone's own alarms keep coming until the first photo is taken (or "Can't today").
@available(iOS 26.0, *)
struct OpenMorningPhotosIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "I'm up"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Chores.shared.showMorningPhotos = true
        await MorningAlarms.stopBed()
        return .result()
    }
}

/// The morning photos: three shots (the face, then each hand), each sent as a photo event (scored nightly like the
/// Shortcut's). The first one taken stops today's alarms and the bed's at once, before anything is sent; the photos go
/// through the app's photo queue (Store.enqueuePhoto: sent in the background, retried until the server has them), so
/// the steps never wait on the network. When all three are taken Morning photos is done; then it says what's next.
struct MorningPhotosView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var chores = Chores.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var camera = false
    @State private var error: String?
    @State private var askSkip = false

    // `name` is what the photo is sent as (the nightly scoring picks its measures by it); the screen only shows `title`
    private let steps: [(name: String, title: String, hint: String, front: Bool)] = [
        ("Face", "Photo front", "Front camera, straight on, no glasses", true),
        ("Left Hand", "Photo left", "Back camera, left side, fingers spread, nails in view", false),
        ("Right Hand", "Photo right", "Back camera, right side, fingers spread, nails in view", false),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if step < steps.count {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 72)).foregroundStyle(.orange)
                    Text("Morning photos").font(.title.bold())
                    Text("\(steps[step].title) (\(step + 1) of \(steps.count))").font(.headline).foregroundStyle(.secondary)
                    Text(steps[step].hint).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button {
                        camera = true
                    } label: {
                        Label("Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
                    Text("Photos done").font(.title.bold())
                    Text("Next: step on the scale, then take your morning supplements.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
            .padding(24)
            .frame(maxHeight: .infinity)
            .navigationTitle("Morning photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                if step < steps.count {
                    ToolbarItem(placement: .primaryAction) { Button("Can't today") { askSkip = true } }
                }
            }
            .confirmationDialog("Skip the morning photos today?", isPresented: $askSkip, titleVisibility: .visible) {
                Button("Skip today", role: .destructive) { Task { await skip() } }
            } message: {
                Text("Today's alarms stop, the bed's alarm too, and the photos come back tomorrow.")
            }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker(front: steps[min(step, steps.count - 1)].front) { image in
                    camera = false
                    if let image { take(image) }
                }
                .ignoresSafeArea()
            }
        }
    }

    /// A photo taken: the alarms stop first (the first photo; on the phone, nothing waits on the server), then the
    /// photo is queued to send in the background and the next step shows at once.
    private func take(_ image: UIImage) {
        if !MorningAlarms.stoppedToday {
            MorningAlarms.cancelToday()
            Task { await MorningAlarms.stopBed() }
        }
        if let data = image.resized(width: 1080).jpegData(compressionQuality: 0.82) {
            store.enqueuePhoto(["id": "app-photo-" + UUID().uuidString, "name": steps[step].name, "kind": "photo",
                                "time": Fmt.iso(Date()), "photo": data.base64EncodedString()])
            error = nil
        } else {
            error = "That photo couldn't be saved; the alarms are off anyway."
        }
        step += 1
        if step == steps.count { Task { await finish() } }
    }

    /// The way out (traveling, the camera broke, ...): today's alarms and the bed's stop, Morning photos waits for
    /// tomorrow, and the skip is logged.
    private func skip() async {
        MorningAlarms.cancelToday()
        await MorningAlarms.stopBed()
        store.enqueue(OutEvent(name: "Morning Photos Skipped", kind: "log", at: Date()))
        await store.flush()
        if let c = chores.chores.first(where: { $0.alarm }), let id = c.id { await chores.act(id, "tomorrow") }
        await chores.refreshMorning()
        dismiss()
    }

    /// All three in: today's alarms go and the bed's stops now (the Morning photos on_done would also stop it). Then,
    /// when set, the sync Shortcut runs while the phone is still unlocked (the weigh-in is next and the phone goes
    /// down): it opens the apps that only sync when opened (Oura, HidrateSpark) and comes back here.
    private func finish() async {
        MorningAlarms.cancelToday()
        MorningSync.run()
        await MorningAlarms.stopBed()
        if let c = chores.chores.first(where: { $0.alarm }), let id = c.id { await chores.act(id, "done") }
        await chores.refreshMorning()
    }
}

/// The system camera (front or back), returning the photo or nil when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let front: Bool
    var flash: UIImagePickerController.CameraFlashMode = .off
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if p.sourceType == .camera {
            p.cameraDevice = front && UIImagePickerController.isCameraDeviceAvailable(.front) ? .front : .rear
            // the morning photos: flash off on every shot, so the light is the same each morning (the room's, not a
            // flash some mornings and not others); a food photo passes .auto
            if UIImagePickerController.isFlashAvailable(for: p.cameraDevice) { p.cameraFlashMode = flash }
        }
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(_ done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension UIImage {
    /// At most `width` px wide (the photo endpoint takes up to 6 MB; ~1080 px is plenty for the scoring).
    func resized(width: CGFloat) -> UIImage {
        guard size.width > width else { return self }
        let h = size.height * width / size.width
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h), format: format).image { _ in
            draw(in: CGRect(x: 0, y: 0, width: width, height: h))
        }
    }
}

/// Wake times and the alarm chain.
struct MorningSettingsView: View {
    @AppStorage(MorningSync.onKey) private var syncOn = false
    @AppStorage(MorningSync.nameKey) private var syncName = MorningSync.defaultName
    @ObservedObject private var chores = Chores.shared
    @Environment(\.dismiss) private var dismiss
    @State private var m = MorningSettings()

    var body: some View {
        NavigationStack {
            Form {
                if m.fromHomeAssistant {
                    Section {
                        Text(m.upcoming.isEmpty ? "No wake-up coming up" : m.upcoming)
                    } header: { Text("Wake up") } footer: {
                        Text("From the wake-up schedule in Home Assistant (each weekday, the override and the one-off wake-up). Change it there.")
                    }
                } else {
                    Section {
                        DatePicker("Weekdays", selection: time($m.weekday), displayedComponents: .hourAndMinute)
                        DatePicker("Weekends and holidays", selection: time($m.weekend), displayedComponents: .hourAndMinute)
                    } header: { Text("Wake up") }
                }
                Section {
                    Toggle("Alarm until the photos are taken", isOn: $m.alarmOn)
                    if m.alarmOn {
                        Stepper("Starts \(m.afterMinutes) min after the wake-up", value: $m.afterMinutes, in: 0...30)
                        Stepper("Again every \(m.everyMinutes) min", value: $m.everyMinutes, in: 1...30)
                        Stepper("\(m.count) alarms", value: $m.count, in: 1...12)
                    }
                } footer: {
                    Text("The bed, blinds and lights start at the wake-up; the alarm follows. On a morning the smart wake may still wait out deep or REM sleep, it counts from the latest the bed may ring. Stopping an alarm only waits for the next one. Taking the morning photos ends today's.")
                }
                Section {
                    Toggle("Sync apps after the photos", isOn: $syncOn)
                    if syncOn {
                        TextField("Shortcut name", text: $syncName).autocorrectionDisabled()
                        Button("Run it now") { MorningSync.run(force: true) }
                    }
                } footer: {
                    Text("Runs this Shortcut right after the last photo, while the phone is still unlocked, so the apps that only sync when opened (Oura, HidrateSpark) sync during the weigh-in. Make it in Shortcuts: Open App Oura, Wait 20 s, Open App HidrateSpark, Wait 20 s, Open App Log.")
                }
            }
            .navigationTitle("Morning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await chores.saveMorning(m); dismiss() } }
                }
            }
            .onAppear { m = chores.morning }
        }
    }

    private func time(_ s: Binding<String>) -> Binding<Date> {
        Binding(get: { ChoreTime.clock(s.wrappedValue) }, set: { s.wrappedValue = ChoreTime.hhmm($0) })
    }
}

/// The apps that only sync when opened, opened by a Shortcut after the morning photos (the phone is unlocked then; the
/// weigh-in comes next). An app can't open others in a row itself, so a Shortcut does it: Open App Oura, Wait,
/// Open App HidrateSpark, Wait, Open App Log. Off until it's made (Morning settings).
enum MorningSync {
    static let onKey = "morningSyncOn", nameKey = "morningSyncShortcut", defaultName = "Sync Apps"

    @MainActor
    static func run(force: Bool = false) {
        let d = UserDefaults.standard
        guard force || d.bool(forKey: onKey) else { return }
        let name = (d.string(forKey: nameKey) ?? defaultName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=" + q) else { return }
        UIApplication.shared.open(url)
    }
}
