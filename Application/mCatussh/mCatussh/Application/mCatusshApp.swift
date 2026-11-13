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
                    CatusshTerminalView.setCopyOnSelect(store.terminalCopyOnSelect)
                    checkAgreement()
                    #if DEBUG
                        seedPreviewServers()
                        seedPreviewVNC()
                        openPreviewTool()
                    #endif
                }
                .onChange(of: store.licenseAgreed) { _ in
                    checkAgreement()
                }
                // The appearance and copy on select may come from another
                // device, through iCloud.
                .onReceive(NotificationCenter.default.publisher(for: CloudSync.settingsDidChange)) { _ in
                    AppearancePreference.applyStored()
                    CatusshTerminalView.setCopyOnSelect(store.terminalCopyOnSelect)
                }
        }
    }

    #if DEBUG
        /// `CATUSSH_PREVIEW_SEED=1` adds sample UU Remote devices, enough
        /// servers for lists that scroll under the bars.
        func seedPreviewServers() {
            guard ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_SEED"] != nil else { return }
            // A folder of its own: syncing devices into a signed-in
            // account's folder would drop that account's real devices.
            let preview = RDFolder.Source.uuRemote(userID: "preview")
            let folder = store.folderGroup.folders.first { $0.source == preview }
                ?? store.createFolder(named: "UU Remote Preview", source: preview)
            let devices = (1 ... 16).map { index -> UUDeviceInfo in
                var device = UUDeviceInfo()
                device.deviceID = "preview-\(index)"
                device.alias = index.isMultiple(of: 2) ? "Studio PC \(index)" : "MacBook Pro \(index)"
                device.platform = index.isMultiple(of: 2) ? 1 : 4
                return device
            }
            var group = store.machineGroup
            UURemoteFolderSync.apply(devices: devices, folder: folder.name, to: &group)
            store.machineGroup = group
        }

        /// `CATUSSH_PREVIEW_VNC=<port>` adds a "Preview VNC" server, a VNC
        /// screen at 127.0.0.1 on that port (the Mac, from the simulator).
        static let previewVNCID = UUID(uuidString: "C0FFEE00-0000-4000-8000-00000000F00D")!

        func seedPreviewVNC() {
            guard let port = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_VNC"] else { return }
            var group = store.machineGroup
            group.insert(RDMachine(
                id: Self.previewVNCID,
                remoteAddress: "127.0.0.1",
                remotePort: "22",
                name: "Preview VNC",
                remoteDesktopProtocol: .vnc,
                vncPort: port
            ))
            store.machineGroup = group
        }

        /// `CATUSSH_PREVIEW_TOOL=terminal|files|monitor|desktop` opens the
        /// first server's page on that tool (for a desktop, Preview VNC or
        /// the first server with one), for screenshots without input.
        func openPreviewTool() {
            let machines = store.machineGroup.machines
            guard let name = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_TOOL"],
                  let tool = ServerTool.allCases.first(where: { $0.title.lowercased() == name }),
                  let machine = tool == .desktop
                  ? machines.first(where: { $0.id == Self.previewVNCID }) ?? machines.first(where: \.hasRemoteDesktop)
                  : machines.first
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tool.open(machine.id)
                SessionNavigation.shared.reveal(.server(machine.id), tool: tool)
            }
        }
    #endif

    func checkAgreement() {
        guard !store.licenseAgreed else {
            return
        }
        let host = UIHostingController(rootView: AgreementView().rxSolidBars())
        host.preferredContentSize = preferredPopOverSize
        host.isModalInPresentation = true
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = .formSheet
        // At launch the window is not in the hierarchy yet; the queue
        // replays the present once it is.
        PresentationQueue.present(next: host)
    }
}

