import SwiftUI

extension View {
    /// A Done button above the keyboard. Number pads have no return key, so
    /// without it a field can't be left except by leaving the screen. Goes on
    /// every screen with a text field; keyboard toolbars don't carry into
    /// pushed screens or sheets.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
    }
}
