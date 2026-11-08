//
//  EditorWorkspace.swift
//  catussh (macOS)
//
//  Platform-specific confirmation wrappers around CatusshModule's shared EditorWorkspace / EditorCenter.
//

import CatusshEditor
import CatusshModule
import SwiftUI

extension EditorWorkspace {
    func close(_ document: EditorDocument) {
        guard document.isEdited else { return remove(document) }
        UIBridge.requiresConfirmation(
            message: "Close \(document.name) without saving?",
            informative: "Your changes are lost if you don't save them.",
            confirmTitle: "Discard Changes",
            destructive: true,
            always: true
        ) { confirmed in
            MainActor.assumeIsolated {
                if confirmed { self.remove(document) }
            }
        }
    }
}

enum EditorSessionActions {
    @MainActor
    static func close(_ workspace: EditorWorkspace) {
        guard workspace.hasUnsavedChanges else { return EditorCenter.shared.end(workspace.id) }
        UIBridge.requiresConfirmation(
            message: "Close the editor on \(workspace.context.machine.name)?",
            informative: "Some files have changes that are not saved. They are lost if you close the editor.",
            confirmTitle: "Discard Changes",
            destructive: true,
            always: true
        ) { confirmed in
            if confirmed { EditorCenter.shared.end(workspace.id) }
        }
    }
}

#if DEBUG
    extension AppRouter {
        @MainActor
        func showEditorPreview() {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let context = FileTransferContext(machine: machine)
            FileTransferManager.shared.transfers.append(context)
            let workspace = EditorCenter.shared.workspace(for: context)
            workspace.addPreview(path: "/etc/nginx/nginx.conf", text: """
            user www-data;
            worker_processes auto;

            http {
                sendfile on;
                keepalive_timeout 65;
                include /etc/nginx/conf.d/*.conf;
            }
            """)
            workspace.addPreview(path: "/opt/web/config.json", text: """
            {
              "port": 8080,
              "workers": 4,
              "logLevel": "info",
              "upstreams": ["10.0.0.11", "10.0.0.12"]
            }
            """)
            workspace.addPreview(path: "/usr/local/bin/rotate-logs.sh", text: """
            #!/usr/bin/env bash
            # Rotate logs and restart the service.
            set -euo pipefail

            LOG_DIR="/var/log/web"
            KEEP=7

            rotate() {
                local file="$1"
                if [[ -s "$file" ]]; then
                    mv "$file" "$file.$(date +%Y%m%d)"
                fi
            }

            for log in "$LOG_DIR"/*.log; do
                rotate "$log"
            done
            find "$LOG_DIR" -name '*.log.*' -mtime +"$KEEP" -delete
            systemctl restart web.service   # pick up new log handles
            """)
            route = .editor(context.id)
        }
    }
#endif
