//
//  View.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import SwiftUI

extension View {
    func expended() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import CatusshModule

/// Shared modal wrapper: a NavigationStack hosting the content with a
/// trailing close button. Replaces the per-context DefaultPresent copies.
struct DefaultModalPresenter<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(.rxAccent)
        .rxSolidBars()
    }
}

func createPreview(creation: () -> AnyView) -> some View {
    Group {
        NavigationStack {
            creation()
                .environmentObject(CatusshStore.shared)
        }
        .previewDevice(PreviewDevice(rawValue: "iPod touch (7th generation)"))
        NavigationStack {
            NavigationLink {
                creation()
                    .environmentObject(CatusshStore.shared)
            } label: {
                Label("Preview Layout", systemImage: "arrow.right")
            }
        }
        .previewDevice(PreviewDevice(rawValue: "iPad mini (6th generation)"))
        .previewInterfaceOrientation(.landscapeLeft)
    }
}
