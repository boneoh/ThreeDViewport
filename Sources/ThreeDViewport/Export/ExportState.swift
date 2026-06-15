import Foundation
import Combine

// Phase 3: Observable export state shared between ViewportView (writer) and
// TimelinePanel (reader). ViewportView writes progress; TimelinePanel binds to it.
final class ExportState: ObservableObject {

    @Published var isExporting: Bool   = false
    @Published var progress:    Float  = 0.0    // 0.0 – 1.0 for the current file
    @Published var lastMessage: String = ""

    // Export Progress panel fields.
    @Published var projectName: String = ""
    @Published var passIndex:   Int    = 0      // 1-based current pass
    @Published var passCount:   Int    = 0      // total passes (1 for a single export)
    @Published var passName:    String = ""     // current pass name (empty for single export)

    init() {
        print("[DEBUG] ExportState: initialized")
    }
}
