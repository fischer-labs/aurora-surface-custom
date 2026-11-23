import SwiftUI
import RoostKit

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.roostBG)
            case .onboarding:
                Text("Onboarding")
            case .ready:
                Text(app.store?.family.name ?? "Roost")
            }
        }
    }
}
