import Combine

// Observable settings for the feedback delay-line system.
// Shared between FeedbackPanel (UI), FeedbackProcessor (GPU), and VideoExporter.
final class FeedbackSettings: ObservableObject {

    // Master enable — when false the scene renders normally with no overhead.
    @Published var isEnabled: Bool  = false

    // How many rendered frames between feedback ticks.
    // 1 = every frame; 10 = every 10th frame; 30 = once per second at 30 fps.
    @Published var interval:  Int   = 10

    // Blend weight: 0.0 = pure scene, 1.0 = pure feedback buffer.
    // Values around 0.3–0.7 give the most interesting results.
    @Published var decay:     Float = 0.5

    // Queue depth: number of feedback frames held in the ring buffer.
    // The feedback tap reads from `length` intervals ago.
    // Nothing appears until the queue is fully primed (length × interval frames).
    @Published var length:    Int   = 10

    init() {
        print("[DEBUG] FeedbackSettings: initialized")
    }
}
