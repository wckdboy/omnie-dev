// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A sheet on the app's own surfaces, rather than the system's grey.
///
/// Left alone, a sheet draws on `systemBackground`/`systemGroupedBackground`, so the app's palette
/// (tuned and tested against `chrome`, `pane`, `editor` and `raised`) is measured against a surface it
/// wasn't designed for — and the sheet looks like another app's. This sets the sheet's own background,
/// the navigation bar's, and hides the scroll content's so the palette shows through a `List` or `Form`.
public struct SheetChrome: ViewModifier {
    @Environment(\.palette) private var palette

    public init() {}

    public func body(content: Content) -> some View {
        #if os(iOS)
        content
            .scrollContentBackground(.hidden)
            .background(palette.surface.pane.color)
            .presentationBackground(palette.surface.pane.color)
            // Rows on the palette's raised surface, like the app's panels, so its text roles are
            // measured against the surface they are tested on.
            .listRowBackground(palette.surface.raised.color)
            .toolbarBackground(palette.surface.chrome.color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        #else
        content
            .scrollContentBackground(.hidden)
            .background(palette.surface.pane.color)
            .listRowBackground(palette.surface.raised.color)
        #endif
    }
}

public extension View {
    /// Puts a sheet on the app's surfaces (see `SheetChrome`).
    func sheetChrome() -> some View { modifier(SheetChrome()) }
}
