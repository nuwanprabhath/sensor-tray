import SwiftUI

/// Stand-in for `@State`: on the macOS 27 SDK `@State` is a macro whose
/// plugin only ships with full Xcode, so builds with the Command Line Tools
/// fail. `@StateObject private var x = ViewState(value)` behaves the same,
/// with `x.value` / `$x.value`.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
