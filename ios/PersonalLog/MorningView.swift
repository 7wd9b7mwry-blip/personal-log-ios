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
    var everyMinutes = 5
    var count = 6
    var photosDoneToday = false

    init() {}

    init(_ j: [String: Any]) {
        weekday = j["weekday"] as? String ?? "07:30"
        weekend = j["weekend"] as? String ?? "09:00"
        let a = j["alarm"] as? [String: Any] ?? [:]
        alarmOn = a["on"] as? Bool ?? true
        everyMinutes = (a["every_minutes"] as? NSNumber)?.intValue ?? 5
        count = (a["count"] as? NSNumber)?.intValue ?? 6
        photosDoneToday = j["photos_done_today"] as? Bool ?? false
    }

    var payload: [String: Any] {
        ["weekday": weekday, "weekend": weekend, "alarm": ["on": alarmOn, "every_minutes": everyMinutes, "count": count]]
    }

    /// The wake time on a day (holidays from the app settings count as weekend).
    func wake(on day: Date, holidays: [String]) -> Date? {
        let weekendDay = Calendar.current.isDateInWeekend(day) || holidays.contains(ChoreTime.dayString(day))
        let p = (weekendDay ? weekend : weekday).split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: day)
    }
}

/// The wake alarm, Wayk style: an alarm at the wake time and another every `everyMinutes`, `count` in all, for the next
/// three days. Stopping one only waits for the next; the chain is cancelled once the morning photos are taken. Alarms
/// are AlarmKit's (iOS 26), so they ring through silent mode and Focus; "Take photos" on the alarm opens the camera.
@MainActor
enum MorningAlarms {
    private static let key = "morningAlarms"   // [ISO date: alarm UUID]

    static func sync(_ m: MorningSettings) async {
        guard #available(iOS 26.0, *) else { return }
        var scheduled = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        var wanted: [String: Date] = [:]
        if m.alarmOn, await authorized() {
            let holidays = Store.shared.config.holidays
            for offset in 0..<3 {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { continue }
                if offset == 0 && m.photosDoneToday { continue }
                guard let wake = m.wake(on: day, holidays: holidays) else { continue }
                for i in 0..<max(1, m.count) {
                    let at = wake.addingTimeInterval(Double(i * max(1, m.everyMinutes) * 60))
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

    /// Today's photos are in: the rest of today's alarms go.
    static func cancelToday() {
        guard #available(iOS 26.0, *) else { return }
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
            title: "Morning photos",
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(text: "Take photos", textColor: .white, systemImageName: "camera.fill"),
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

/// The alarm's "Take photos" button: opens the app on the photo steps.
@available(iOS 26.0, *)
struct OpenMorningPhotosIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Take morning photos"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Chores.shared.showMorningPhotos = true
        return .result()
    }
}

/// Face, then left hand, then right hand, each with the camera, each sent as a photo event (scored nightly like the
/// Shortcut's). When all three are in, today's alarms stop and Morning photos is done; then it says what's next.
struct MorningPhotosView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var chores = Chores.shared
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var camera = false
    @State private var sending = false
    @State private var error: String?

    private let steps: [(name: String, hint: String, front: Bool)] = [
        ("Face", "Look straight at the camera, even light, no glasses", true),
        ("Left Hand", "Back of the left hand, fingers spread, nails in view", false),
        ("Right Hand", "Back of the right hand, fingers spread, nails in view", false),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if step < steps.count {
                    Text("\(step + 1) of \(steps.count)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: steps[step].front ? "face.smiling" : "hand.raised")
                        .font(.system(size: 72)).foregroundStyle(.orange)
                    Text(steps[step].name).font(.title.bold())
                    Text(steps[step].hint).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button {
                        camera = true
                    } label: {
                        Label(sending ? "Sending…" : "Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(sending)
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker(front: steps[min(step, steps.count - 1)].front) { image in
                    camera = false
                    if let image { Task { await send(image) } }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func send(_ image: UIImage) async {
        sending = true
        defer { sending = false }
        guard let data = image.resized(width: 1080).jpegData(compressionQuality: 0.82) else { return }
        let name = steps[step].name
        let event: [String: Any] = ["id": "app-photo-" + UUID().uuidString, "name": name, "kind": "photo",
                                    "time": Fmt.iso(Date()), "photo": data.base64EncodedString()]
        do {
            let r = try await API(creds: store.creds).rpc("ingest_event", json: ["events": [event]])
            let j = (try? JSONSerialization.jsonObject(with: r)) as? [String: Any] ?? [:]
            if let rejected = j["rejected"] as? [[String: Any]], !rejected.isEmpty {
                error = "Not accepted: \(rejected.first?["error"] ?? "")"
                return
            }
            error = nil
            step += 1
            if step == steps.count { await finish() }
        } catch {
            self.error = "Couldn't send it: \(error.localizedDescription). Try again."
        }
    }

    private func finish() async {
        MorningAlarms.cancelToday()
        if let c = chores.chores.first(where: { $0.alarm }), let id = c.id { await chores.act(id, "done") }
        await chores.refreshMorning()
    }
}

/// The system camera (front or back), returning the photo or nil when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let front: Bool
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if p.sourceType == .camera {
            p.cameraDevice = front && UIImagePickerController.isCameraDeviceAvailable(.front) ? .front : .rear
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
    @ObservedObject private var chores = Chores.shared
    @Environment(\.dismiss) private var dismiss
    @State private var m = MorningSettings()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Weekdays", selection: time($m.weekday), displayedComponents: .hourAndMinute)
                    DatePicker("Weekends and holidays", selection: time($m.weekend), displayedComponents: .hourAndMinute)
                } header: { Text("Wake up") }
                Section {
                    Toggle("Alarm until the photos are taken", isOn: $m.alarmOn)
                    if m.alarmOn {
                        Stepper("Again every \(m.everyMinutes) min", value: $m.everyMinutes, in: 1...30)
                        Stepper("\(m.count) alarms", value: $m.count, in: 1...12)
                    }
                } footer: {
                    Text("Stopping an alarm only waits for the next one. Taking the face and hand photos ends today's.")
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
