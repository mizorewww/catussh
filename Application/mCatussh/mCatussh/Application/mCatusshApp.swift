//
//  mCatusshApp.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import SwiftUI
import CatusshTerminal

@main
struct mCatusshApp: App {
    @StateObject private var store = CatusshStore.shared

    init() {
        #if DEBUG
            NSLog("\nCommand Arguments:\n" + CommandLine.arguments.joined(separator: "\n"))
        #endif

        // Shared file-transfer core lives in CatusshModule; register the
        // platform UI handler it delegates to.
        FileTransferInterface.uiHandler = IOSFileTransferUIHandler()
        TerminalInterface.uiHandler = IOSTerminalUIHandler()

        _ = LogRedirect.shared
        _ = CatusshStore.shared
        CloudSync.shared.start()

        NSLog("static main completed")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { url in
                    // uuremote:// external integration callbacks arrive on
                    // the app's own catussh:// scheme.
                    UULocalBridge.handleCallback(url)
                }
                #if DEBUG
                .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_EDITOR"] != nil)) {
                    EditorPreviewScreen()
                }
                #endif
                .onAppear {
                    AppearancePreference.applyStored()
                    checkAgreement()
                }
                .onChange(of: store.licenseAgreed) { _ in
                    checkAgreement()
                }
                // The appearance may come from another device, through iCloud.
                .onReceive(NotificationCenter.default.publisher(for: CloudSync.settingsDidChange)) { _ in
                    AppearancePreference.applyStored()
                }
        }
    }

    func checkAgreement() {
        guard !store.licenseAgreed else {
            return
        }
        let host = UIHostingController(rootView: AgreementView())
        host.preferredContentSize = preferredPopOverSize
        host.isModalInPresentation = true
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = .formSheet
        // At launch the window is not in the hierarchy yet; the queue
        // replays the present once it is.
        PresentationQueue.present(next: host)
    }
}
