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
    @Published var hdrFolderPath:       String     // default folder for the HDR pickers
    @Published var exportedModelsPath:  String     // where Export Model writes the .glb
    @Published var exportedModelProjectsPath: String  // companion source .3dvp for envelopes
    @Published var exportWidth:         Int
    @Published var exportHeight:        Int
    @Published var exportCodecID:       String     // ExportCodec.id

    // Auto-keyframe on edit: when editing an already-animated entity, capture the
    // change as a keyframe so a scrub/play doesn't discard it.  Two independent modes.
    @Published var autoKeyframeUpdateNearby:  Bool  // update the keyframe under the playhead
    @Published var autoKeyframeInsertBetween: Bool  // add a keyframe when between keyframes

    // Viewport movement sensitivity multipliers (1.0 = the default 1:1 feel).
    @Published var dragSensitivity:  Double   // mouse-drag move scale
    @Published var arrowSensitivity: Double   // arrow-key / +- depth step scale

    enum Defaults {
        static let projects  = "~/Documents/ThreeDViewport/Projects"
        static let movies    = "~/Documents/ThreeDViewport/Movies"
        static let modelsFav = "~/Documents/ThreeDViewport/Models/Favorites"
        static let models    = "~/Documents/ThreeDViewport/Models"
        static let hdrs      = "~/Documents/ThreeDViewport/HDRs"
        static let exportedModels    = "~/Documents/ThreeDViewport/Models/Exported"
        static let exportedProjects  = "~/Documents/ThreeDViewport/Models/Exported/Projects"
        static let width     = 1920
        static let height    = 1080
        static let codecID   = "proRes4444"
        static let autoKeyUpdate = false
        static let autoKeyInsert = false
        static let dragSensitivity:  Double = 1.0
        static let arrowSensitivity: Double = 1.0
    }

    init(projectsPath:        String = Defaults.projects,
         moviesPath:          String = Defaults.movies,
         modelsPathPrimary:   String = Defaults.modelsFav,
         modelsPathSecondary: String = Defaults.models,
         hdrFolderPath:       String = Defaults.hdrs,
         exportedModelsPath:        String = Defaults.exportedModels,
         exportedModelProjectsPath: String = Defaults.exportedProjects,
         exportWidth:         Int    = Defaults.width,
         exportHeight:        Int    = Defaults.height,
         exportCodecID:       String = Defaults.codecID,
         autoKeyframeUpdateNearby:  Bool = Defaults.autoKeyUpdate,
         autoKeyframeInsertBetween: Bool = Defaults.autoKeyInsert,
         dragSensitivity:  Double = Defaults.dragSensitivity,
         arrowSensitivity: Double = Defaults.arrowSensitivity) {
        self.projectsPath        = projectsPath
        self.moviesPath          = moviesPath
        self.modelsPathPrimary   = modelsPathPrimary
        self.modelsPathSecondary = modelsPathSecondary
        self.hdrFolderPath       = hdrFolderPath
        self.exportedModelsPath        = exportedModelsPath
        self.exportedModelProjectsPath = exportedModelProjectsPath
        self.exportWidth         = exportWidth
        self.exportHeight        = exportHeight
        self.exportCodecID       = exportCodecID
        self.autoKeyframeUpdateNearby  = autoKeyframeUpdateNearby
        self.autoKeyframeInsertBetween = autoKeyframeInsertBetween
        self.dragSensitivity  = dragSensitivity
        self.arrowSensitivity = arrowSensitivity
    }

    // MARK: - Persistence

    // Codable mirror — keeps Codable separate from the @Published observable.
    private struct Stored: Codable {
        var projectsPath:        String
        var moviesPath:          String
        var modelsPathPrimary:   String
        var modelsPathSecondary: String
        var hdrFolderPath:       String?   // optional: older settings.json predate it
        var exportedModelsPath:        String?   // optional: older files predate them
        var exportedModelProjectsPath: String?
        var exportWidth:         Int
        var exportHeight:        Int
        var exportCodecID:       String
        var autoKeyframeUpdateNearby:  Bool?   // optional: older files predate them
        var autoKeyframeInsertBetween: Bool?
        var dragSensitivity:  Double?   // optional: older files predate them
        var arrowSensitivity: Double?
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
                           hdrFolderPath:       s.hdrFolderPath ?? Defaults.hdrs,
                           exportedModelsPath:        s.exportedModelsPath        ?? Defaults.exportedModels,
                           exportedModelProjectsPath: s.exportedModelProjectsPath ?? Defaults.exportedProjects,
                           exportWidth:         s.exportWidth,
                           exportHeight:        s.exportHeight,
                           exportCodecID:       s.exportCodecID,
                           autoKeyframeUpdateNearby:  s.autoKeyframeUpdateNearby  ?? Defaults.autoKeyUpdate,
                           autoKeyframeInsertBetween: s.autoKeyframeInsertBetween ?? Defaults.autoKeyInsert,
                           dragSensitivity:  s.dragSensitivity  ?? Defaults.dragSensitivity,
                           arrowSensitivity: s.arrowSensitivity ?? Defaults.arrowSensitivity)
    }

    func save() {
        let s = Stored(projectsPath:        projectsPath,
                       moviesPath:          moviesPath,
                       modelsPathPrimary:   modelsPathPrimary,
                       modelsPathSecondary: modelsPathSecondary,
                       hdrFolderPath:       hdrFolderPath,
                       exportedModelsPath:        exportedModelsPath,
                       exportedModelProjectsPath: exportedModelProjectsPath,
                       exportWidth:         exportWidth,
                       exportHeight:        exportHeight,
                       exportCodecID:       exportCodecID,
                       autoKeyframeUpdateNearby:  autoKeyframeUpdateNearby,
                       autoKeyframeInsertBetween: autoKeyframeInsertBetween,
                       dragSensitivity:  dragSensitivity,
                       arrowSensitivity: arrowSensitivity)
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
