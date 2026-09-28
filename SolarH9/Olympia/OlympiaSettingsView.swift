import SwiftUI
import UniformTypeIdentifiers

struct OlympiaSettingsView: View {
    @ObservedObject var store: OlympiaTrainingStore
    @Environment(\.olympiaColors) private var colors
    @AppStorage("olympia.units") private var units = "lb"
    @AppStorage("olympia.theme") private var theme = "dark"
    @AppStorage("olympia.accent") private var accent = "sky"
    @AppStorage("olympia.displayName") private var displayName = ""
    @State private var importKind: ImportKind?
    @State private var showImporter = false
    @State private var importReport: OlympiaImportReport?
    @State private var backupURL: URL?
    @State private var alertMessage: String?
    @StateObject private var cloud = OlympiaCloud.shared
    @State private var email = ""
    @State private var password = ""
    @State private var showSensor = false
    private enum ImportKind: String, Identifiable { case workouts, weights; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.title2.bold())
                settingsSection {
                    HStack(spacing: 12) {
                        Image("OlympiaMark").resizable().scaledToFit().frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading) {
                            Text("Olympia").font(.headline)
                            Text("Your training data stays on this iPhone until cloud sync is connected.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                settingsSection("Profile") {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name).textInputAutocapitalization(.words)
                        .modifier(SettingsPillField())
                    if let email = cloud.signedInEmail { Text(email).font(.caption).foregroundStyle(.secondary) }
                }
                settingsSection("Appearance") {
                    LabeledContent("Mode") {
                        Picker("Mode", selection: $theme) {
                            Text("System").tag("system"); Text("Dark").tag("dark"); Text("Light").tag("light")
                        }.labelsHidden().pickerStyle(.menu).modifier(SettingsPillField())
                    }
                    LabeledContent("Accent") {
                        Picker("Accent", selection: $accent) {
                            Text("Ember orange").tag("ember")
                            Text("Sky blue").tag("sky"); Text("Emerald").tag("emerald")
                            Text("Violet").tag("violet"); Text("Sunset").tag("sunset")
                        }.labelsHidden().pickerStyle(.menu).modifier(SettingsPillField())
                    }
                }
                settingsSection("Workout preferences") {
                    LabeledContent("Weight units") {
                        Picker("Weight units", selection: $units) { Text("Pounds (lb)").tag("lb"); Text("Kilograms (kg)").tag("kg") }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsPillField())
                    }
                }
                settingsSection("Data & privacy") {
                    Button { exportBackup() } label: {
                        Label("Export all training data", systemImage: "square.and.arrow.up")
                    }
                    if let backupURL { ShareLink("Share backup", item: backupURL) }
                    Button { importKind = .workouts; showImporter = true } label: {
                        Label("Import workout data", systemImage: "square.and.arrow.down")
                    }
                    Button { importKind = .weights; showImporter = true } label: {
                        Label("Import body weight data", systemImage: "square.and.arrow.down")
                    }
                    Text("Import a workout note or text file. Logged workouts become quick adds when you create a workout in Program. Weight logs can be imported separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                settingsSection("Heart rate") {
                    Button { showSensor = true } label: {
                        Label("Connect or view heart-rate sensor", systemImage: "heart.text.square")
                    }
                    Text("Use Live to connect a Bluetooth heart-rate strap or a device broadcasting the standard Heart Rate Service. Live Activities show sensor readings while the app is open or backgrounded when iOS permits.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Heart-rate metrics are for fitness and wellness, not diagnosis or emergency monitoring.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                settingsSection("Cloud sync · Supabase") {
                    TextField("Project URL", text: $cloud.projectURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .modifier(SettingsPillField())
                    SecureField("Publishable / anon key", text: $cloud.publishableKey)
                        .modifier(SettingsPillField())
                    if cloud.signedIn {
                        Text(cloud.signedInEmail ?? "Signed in").font(.caption).foregroundStyle(.secondary)
                        Button(cloud.isBusy ? "Syncing…" : "Sync now") { Task { await cloud.sync(store: store) } }
                            .disabled(cloud.isBusy)
                        Button("Sign out", role: .destructive) { cloud.signOut() }
                    } else {
                        TextField("Email", text: $email).textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress).autocorrectionDisabled()
                            .modifier(SettingsPillField())
                        SecureField("Password", text: $password)
                            .modifier(SettingsPillField())
                        HStack {
                            Button { Task { await cloud.signIn(email: email, password: password) } } label: {
                                Text("Sign in").font(.subheadline.bold()).foregroundStyle(.white)
                                    .padding(.horizontal, 22).frame(minHeight: 44)
                                    .background(colors.accent, in: Capsule())
                            }
                            Spacer()
                            Button("Create account") { Task { await cloud.signUp(email: email, password: password) } }
                        }.disabled(!cloud.configured || cloud.isBusy || email.isEmpty || password.count < 6)
                    }
                    if let message = cloud.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Text("Create a free Supabase project and run the included schema.sql first. Only use its publishable key here—not a service-role key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
              }.padding(20)
            }
            .font(.subheadline)
            .foregroundStyle(colors.text)
            .buttonStyle(OlympiaPressStyle())
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(colors.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSensor) {
                LiveView()
                    .presentationBackground(colors.background)
                    .presentationCornerRadius(24)
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(colors.isLight ? .light : .dark)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .utf8PlainText], allowsMultipleSelection: false) { result in
                guard let kind = importKind else { return }
                importKind = nil
                do {
                    let url = try result.get().first!
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    importReport = kind == .workouts
                        ? OlympiaNoteImporter.importWorkouts(text, into: store)
                        : OlympiaNoteImporter.importWeights(text, into: store)
                    let report = importReport!
                    alertMessage = "Imported \(report.sessions) workouts, \(report.sets) sets, and \(report.weights) weights. \(report.skipped) lines were skipped.\(kind == .workouts && report.sessions > 0 ? " Your logged workouts are now available as quick adds in Program." : "")"
                } catch { alertMessage = error.localizedDescription }
            }
            .alert("Import / export", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("OK") { alertMessage = nil }
            } message: { Text(alertMessage ?? "") }
        }.tint(colors.accent)
    }

    private func settingsSection<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.subheadline.bold()).foregroundStyle(colors.text) }
            OlympiaCard {
                VStack(alignment: .leading, spacing: 16, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func exportBackup() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(OlympiaBackup(store: store))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Olympia-Backup.json")
            try data.write(to: url, options: .atomic)
            backupURL = url
        } catch { alertMessage = error.localizedDescription }
    }
}

private struct SettingsPillField: ViewModifier {
    @Environment(\.olympiaColors) private var colors
    func body(content: Content) -> some View {
        content.font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44)
            .background(colors.secondarySurface, in: Capsule())
    }
}
