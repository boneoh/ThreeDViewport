import SwiftUI

/// Options gathered in the "Bake Scene to HDR" save panel's accessory view.
final class BakeOptions: ObservableObject {
    @Published var resIndex: Int          = 0      // 0 = 2K, 1 = 4K
    @Published var includeBackground: Bool = true

    var width:  Int { resIndex == 1 ? 4096 : 2048 }
    var height: Int { resIndex == 1 ? 2048 : 1024 }
}

/// Accessory shown in the bake save panel — resolution + backdrop choice.
struct BakeOptionsView: View {
    @ObservedObject var options: BakeOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Resolution").frame(width: 90, alignment: .leading)
                Picker("", selection: $options.resIndex) {
                    Text("2048 × 1024 (2K)").tag(0)
                    Text("4096 × 2048 (4K)").tag(1)
                }
                .labelsHidden()
                .frame(width: 200)
            }
            Toggle("Include current environment background", isOn: $options.includeBackground)
            Text("Exports the visible, lit scene seen from the probe. Hide anything you "
                + "don't want captured.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 400)
    }
}
