import AppKit
import SwiftUI

@MainActor
private final class CompressionForm: ObservableObject {
    @Published var name: String
    @Published var destination: URL
    @Published var format: CompressionOptions.Format = .zip
    @Published var level = 5
    @Published var split = false
    @Published var size = "25"
    @Published var password = ""
    @Published var repeatPassword = ""
    @Published var showPassword = false
    @Published var aes = true
    @Published var encryptNames = true
    @Published var excludeResources = true
    @Published var verify = true
    @Published var separate = false
    @Published var trash = false

    init(files: [URL]) {
        name = files.count == 1 ? files[0].lastPathComponent : "Archive"
        destination = files.first?.deletingLastPathComponent() ?? .downloadsDirectory
    }
}

struct CompressionSheet: View {
    let files: [URL]
    let create: (CompressionOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form: CompressionForm

    init(files: [URL], create: @escaping (CompressionOptions) -> Void) {
        self.files = files
        self.create = create
        _form = StateObject(wrappedValue: CompressionForm(files: files))
    }

    private var volumeBytes: Int64? {
        guard form.split, let count = Int64(form.size), (1...1_048_576).contains(count) else { return nil }
        return count * 1_048_576
    }

    private var validation: String? {
        if !Compressor.validName(form.name) { return "Enter an archive name." }
        if form.split && volumeBytes == nil { return "Enter a volume size between 1 and 1,048,576 MiB." }
        if form.password != form.repeatPassword { return "The passwords must match." }
        if !form.password.isEmpty { return Compressor.passwordError(form.password, format: form.format) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create Archive").font(.title2.bold())
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) selected items")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("Format", selection: $form.format) {
                    ForEach(CompressionOptions.Format.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .accessibilityLabel("Archive format")
            }
            .padding(.bottom, 14)

            Form {
                Section("Output") {
                    TextField("Archive name", text: $form.name)
                    LabeledContent("Save to") {
                        Button(form.destination.lastPathComponent + "…", action: chooseDestination)
                            .help(form.destination.path)
                    }
                    Picker("Compression", selection: $form.level) {
                        Text("Store only").tag(0)
                        Text("Fast").tag(3)
                        Text("Normal").tag(5)
                        Text("Maximum").tag(9)
                    }
                    Toggle("Split into volumes", isOn: $form.split)
                    if form.split {
                        LabeledContent("Volume size") {
                            HStack {
                                TextField("25", text: $form.size)
                                    .frame(width: 70)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel("Volume size in MiB")
                                Text("MiB").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Encryption") {
                    HStack {
                        PasswordField(label: "Password (optional)", text: $form.password, visible: form.showPassword)
                        Button { form.showPassword.toggle() } label: {
                            Image(systemName: form.showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(form.showPassword ? "Hide passwords" : "Show passwords")
                    }
                    if !form.password.isEmpty || !form.repeatPassword.isEmpty {
                        PasswordField(label: "Confirm password", text: $form.repeatPassword, visible: form.showPassword)
                        if form.format == .zip {
                            Toggle("Use AES-256", isOn: $form.aes)
                            if !form.aes {
                                Text("Uses legacy ZipCrypto for compatibility.").foregroundStyle(.secondary)
                            }
                        } else {
                            LabeledContent("Encryption", value: "AES-256")
                            Toggle("Encrypt filenames", isOn: $form.encryptNames)
                        }
                    }
                }

                Section("Options") {
                    Toggle("Exclude Mac resource files", isOn: $form.excludeResources)
                    Toggle("Verify archive after compression", isOn: $form.verify)
                        .disabled(form.trash)
                    Toggle("Archive each selected item separately", isOn: $form.separate)
                        .disabled(files.count == 1)
                    Toggle("Move originals to Trash after verification", isOn: $form.trash)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: 412)

            Divider().padding(.top, 10)
            HStack {
                if let validation {
                    Text(validation).foregroundStyle(.secondary).font(.caption)
                } else if form.trash {
                    Text("Originals are moved to Trash after the archive passes verification.")
                        .foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Compress") {
                    let secret = form.password.isEmpty ? nil : form.password
                    let options = CompressionOptions(format: form.format, level: form.level, volumeBytes: volumeBytes,
                        password: secret, aes: form.aes, encryptNames: form.encryptNames,
                        excludeResources: form.excludeResources, verify: form.verify || form.trash, separate: form.separate,
                        trashSources: form.trash, name: form.name, destination: form.destination)
                    form.password = ""
                    form.repeatPassword = ""
                    dismiss()
                    create(options)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validation != nil)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 506)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.directoryURL = form.destination
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let folder = panel.url { form.destination = folder }
    }
}

@MainActor
private final class PasswordForm: ObservableObject {
    @Published var password = ""
    @Published var showPassword = false
}

struct PasswordSheet: View {
    let title: String
    let retry: Bool
    let unlock: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = PasswordForm()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(retry ? "Try the Password Again" : "Unlock Archive", systemImage: "lock")
                .font(.title2.bold())
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                PasswordField(label: "Archive password", text: $form.password, visible: form.showPassword)
                    .focused($focused)
                Button { form.showPassword.toggle() } label: {
                    Image(systemName: form.showPassword ? "eye.slash" : "eye")
                }
                .accessibilityLabel(form.showPassword ? "Hide password" : "Show password")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Unlock") {
                    let secret = form.password
                    form.password = ""
                    unlock(secret)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ArchiveEngine.validPassword(form.password))
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

private struct PasswordField: View {
    let label: String
    @Binding var text: String
    let visible: Bool

    var body: some View {
        if visible {
            TextField(label, text: $text)
        } else {
            SecureField(label, text: $text)
        }
    }
}
