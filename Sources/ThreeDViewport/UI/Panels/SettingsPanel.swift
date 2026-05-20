import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Global settings editor.  Edits a local working copy seeded from AppSettings;
// Save commits + writes the JSON file, Cancel discards.  HDR path takes effect
// on next launch (IBL precompute is startup-only).
struct SettingsPanel: View {

    @ObservedObject var settings: AppSettings
    var onClose: () -> Void

    // Working copies — committed only on Save.
    @State private var projectsPath        = ""
    @State private var moviesPath          = ""
    @State private var modelsPathPrimary   = ""
    @State private var modelsPathSecondary = ""
    @State private var hdrPath             = ""
    @State private var exportWidth         = ""
    @State private var exportHeight        = ""
    @State private var codecIndex          = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            Divider()

            Text("Folders").font(.subheadline).foregroundColor(.secondary)
            pathRow("Projects",          $projectsPath,        directory: true)
            pathRow("Movies",            $moviesPath,          directory: true)
            pathRow("Models (primary)",  $modelsPathPrimary,   directory: true)
            pathRow("Models (fallback)", $modelsPathSecondary, directory: true)

            Divider()

            Text("Environment").font(.subheadline).foregroundColor(.secondary)
            pathRow("HDR file", $hdrPath, directory: false)
            Text("Leave blank to use the bundled studio HDR. Takes effect on next launch.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("Export").font(.subheadline).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text("Resolution").frame(width: 120, alignment: .leading)
                TextField("W", text: $exportWidth).frame(width: 64)
                Text("×")
                TextField("H", text: $exportHeight).frame(width: 64)
            }
            HStack(spacing: 8) {
                Text("Codec").frame(width: 120, alignment: .leading)
                Picker("", selection: $codecIndex) {
                    Text("ProRes 4444").tag(0)
                    Text("ProRes 422 HQ").tag(1)
                }
                .labelsHidden()
                .frame(width: 180)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear(perform: seed)
    }

    // MARK: - Rows

    @ViewBuilder
    private func pathRow(_ label: String,
                         _ binding: Binding<String>,
                         directory: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 120, alignment: .leading)
            TextField("", text: binding)
            Button("Choose…") { choose(binding, directory: directory) }
        }
    }

    // MARK: - Actions

    private func seed() {
        projectsPath        = settings.projectsPath
        moviesPath          = settings.moviesPath
        modelsPathPrimary   = settings.modelsPathPrimary
        modelsPathSecondary = settings.modelsPathSecondary
        hdrPath             = settings.hdrPath
        exportWidth         = String(settings.exportWidth)
        exportHeight        = String(settings.exportHeight)
        codecIndex          = settings.exportCodecID == "proRes422HQ" ? 1 : 0
    }

    private func saveAndClose() {
        settings.projectsPath        = projectsPath
        settings.moviesPath          = moviesPath
        settings.modelsPathPrimary   = modelsPathPrimary
        settings.modelsPathSecondary = modelsPathSecondary
        settings.hdrPath             = hdrPath
        settings.exportWidth         = Int(exportWidth)  ?? settings.exportWidth
        settings.exportHeight        = Int(exportHeight) ?? settings.exportHeight
        settings.exportCodecID       = codecIndex == 1 ? "proRes422HQ" : "proRes4444"
        settings.save()
        onClose()
    }

    private func choose(_ binding: Binding<String>, directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories     = directory
        panel.canChooseFiles           = !directory
        panel.allowsMultipleSelection  = false
        if !directory, let hdr = UTType(filenameExtension: "hdr") {
            panel.allowedContentTypes = [hdr]
        }
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
