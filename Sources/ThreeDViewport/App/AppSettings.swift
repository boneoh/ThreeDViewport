import Foundation
import Combine

// Global, app-wide configuration persisted to
// ~/Library/Application Support/ThreeDViewport/settings.json.
//
// Per-SCENE look settings (exposure, IBL intensity, color mode, background, …)
// live in the project file, NOT here.  This holds only workflow/environment
// config that is the same across every project.
final class AppSettings: ObservableObject {

    /// Shared instance, loaded from disk on first access.
    static let shared = AppSettings.load()

    // Paths are stored verbatim (may contain "~"); call AppSettings.expand(_:)
    // at the point of use to get a concrete URL.
    @Published var projectsPath:        String
    @Published var moviesPath:          String
    @Published var modelsPathPrimary:   String     // tried first (e.g. Favorites)
    @Published var modelsPathSecondary: String     // fallback if primary missing
    @Published var exportWidth:         Int
    @Published var exportHeight:        Int
    @Published var exportCodecID:       String     // ExportCodec.id

    enum Defaults {
        static let projects  = "~/Documents/ThreeDViewport/Projects"
        static let movies    = "~/Documents/ThreeDViewport/Movies"
        static let modelsFav = "~/Documents/ThreeDViewport/Models/Favorites"
        static let models    = "~/Documents/ThreeDViewport/Models"
        static let width     = 1920
        static let height    = 1080
        static let codecID   = "proRes4444"
    }

    init(projectsPath:        String = Defaults.projects,
         moviesPath:          String = Defaults.movies,
         modelsPathPrimary:   String = Defaults.modelsFav,
         modelsPathSecondary: String = Defaults.models,
         exportWidth:         Int    = Defaults.width,
         exportHeight:        Int    = Defaults.height,
         exportCodecID:       String = Defaults.codecID) {
        self.projectsPath        = projectsPath
        self.moviesPath          = moviesPath
        self.modelsPathPrimary   = modelsPathPrimary
        self.modelsPathSecondary = modelsPathSecondary
        self.exportWidth         = exportWidth
        self.exportHeight        = exportHeight
        self.exportCodecID       = exportCodecID
    }

    // MARK: - Persistence

    // Codable mirror — keeps Codable separate from the @Published observable.
    private struct Stored: Codable {
        var projectsPath:        String
        var moviesPath:          String
        var modelsPathPrimary:   String
        var modelsPathSecondary: String
        var exportWidth:         Int
        var exportHeight:        Int
        var exportCodecID:       String
    }

    static func settingsURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeDViewport", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        let url = settingsURL()
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else {
            print("[DEBUG] AppSettings: no readable settings file — using defaults")
            return AppSettings()
        }
        print("[DEBUG] AppSettings: loaded from " + url.path)
        return AppSettings(projectsPath:        s.projectsPath,
                           moviesPath:          s.moviesPath,
                           modelsPathPrimary:   s.modelsPathPrimary,
                           modelsPathSecondary: s.modelsPathSecondary,
                           exportWidth:         s.exportWidth,
                           exportHeight:        s.exportHeight,
                           exportCodecID:       s.exportCodecID)
    }

    func save() {
        let s = Stored(projectsPath:        projectsPath,
                       moviesPath:          moviesPath,
                       modelsPathPrimary:   modelsPathPrimary,
                       modelsPathSecondary: modelsPathSecondary,
                       exportWidth:         exportWidth,
                       exportHeight:        exportHeight,
                       exportCodecID:       exportCodecID)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(s).write(to: Self.settingsURL(), options: .atomic)
            print("[DEBUG] AppSettings: saved to " + Self.settingsURL().path)
        } catch {
            print("[DEBUG] AppSettings: save failed — \(error)")
        }
    }

    // MARK: - Helpers

    /// Expands a stored path (with "~") into a concrete file URL.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
