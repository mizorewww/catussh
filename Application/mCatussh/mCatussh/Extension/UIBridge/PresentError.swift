//
//  PresentError.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/9.
//

import CatusshModule
import SwiftUI
import UIKit

extension UIBridge {
    static func presentSuccess(with message: String, subtitle: String? = nil) {
        presentBanner(title: message, subtitle: subtitle, isError: false, delay: 0)
    }

    static func presentAlert(with message: String) {
        onMainThread {
            let alert = UIAlertController(title: "", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Done", style: .default, handler: nil))
            UIWindow.shutUpKeyWindow?.topMostViewController?.present(alert, animated: true, completion: nil)
        }
    }

    static func presentError(with message: String, delay: Double = 0) {
        debugPrint("<InterfaceError> \(message)")
        let title = message.count > 40 ? String(message.prefix(40)) + "…" : message
        presentBanner(title: title, subtitle: nil, isError: true, delay: delay)
    }

    private static func presentBanner(title: String, subtitle: String?, isError: Bool, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(isError ? .error : .success)

            guard let window = UIWindow.shutUpKeyWindow else { return }
            let banner = UIHostingController(rootView: BannerToastView(title: title, subtitle: subtitle, isError: isError))
            banner.view.backgroundColor = .clear
            banner.view.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(banner.view)

            NSLayoutConstraint.activate([
                banner.view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                banner.view.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
                banner.view.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 16),
                banner.view.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -16),
            ])

            banner.view.alpha = 0
            banner.view.transform = CGAffineTransform(translationX: 0, y: -24)
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.6) {
                banner.view.alpha = 1
                banner.view.transform = .identity
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                UIView.animate(withDuration: 0.2, animations: {
                    banner.view.alpha = 0
                    banner.view.transform = CGAffineTransform(translationX: 0, y: -24)
                }, completion: { _ in
                    banner.view.removeFromSuperview()
                })
            }
        }
    }
}

private struct BannerToastView: View {
    let title: String
    let subtitle: String?
    let isError: Bool

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isError ? Color.rxDanger : Color.rxAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.vertical, RX.Space.s2)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.rxHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
    }
}
