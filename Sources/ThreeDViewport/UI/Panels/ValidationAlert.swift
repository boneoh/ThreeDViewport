import SwiftUI

// Shared validation-alert convention.  Use this for input errors that block an
// action (instead of an easy-to-miss inline label) so the behaviour is consistent
// across every panel: set a non-nil message to raise it; OK clears it.
extension View {
    func validationAlert(_ message: Binding<String?>,
                         title: String = "Invalid Input") -> some View {
        alert(title,
              isPresented: Binding(get: { message.wrappedValue != nil },
                                   set: { if !$0 { message.wrappedValue = nil } }),
              presenting: message.wrappedValue) { _ in
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: { msg in
            Text(msg)
        }
    }
}
