import Foundation
import Combine

// Phase 3: Observable export state shared between ViewportView (writer) and
// TimelinePanel (reader). ViewportView writes progress; TimelinePanel binds to it.
final class ExportState: ObservableObject {

    @Published var isExporting: Bool   = false
    @Published var progress:    Float  = 0.0    // 0.0 – 1.0
    @Published var lastMessage: String = ""

    init() {
        print("[DEBUG] ExportState: initialized")
    }
}
