#if os(iOS)
import AVFoundation
import LumaRemoteCore
import SwiftUI
import UIKit

/// The camera, reading the pairing QR code the TV shows. Asks for camera access first; a refusal or a
/// device without a camera leaves a way back to typing the code.
struct QRScannerView: View {
    let onInvite: (PairingInvite) -> Void

    @Environment(\.lumaRemoteTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var access = CameraAccess.current
    @State private var wrongCode = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch access {
            case .allowed:
                CameraPreview { payload in
                    guard let url = URL(string: payload), let invite = PairingInvite(url: url) else {
                        wrongCode = true
                        return
                    }
                    onInvite(invite)
                }
                .ignoresSafeArea()
                .accessibilityLabel(Text("Camera"))
                .accessibilityHint(Text("Point it at the code on the TV"))
                Viewfinder(wrongCode: wrongCode)
            case .undecided:
                ProgressView()
            case .refused:
                message("Camera access is off for this app. Allow it in Settings, or type the code instead.", button: "Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .unavailable:
                message("This device has no camera to scan with. Type the code shown on the TV instead.")
            }
        }
        .task {
            if access == .undecided { access = await CameraAccess.request() }
        }
        .task(id: wrongCode) {
            guard wrongCode else { return }
            try? await Task.sleep(for: .seconds(2))
            wrongCode = false
        }
    }

    private func message(_ text: String, button: String? = nil, action: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 20) {
            Text(text)
                .font(theme.font(.body))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
            if let button {
                Button(button, action: action)
                    .font(theme.font(.body, weight: .semibold))
                    .foregroundStyle(theme.palette.accentInk)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 50)
                    .background(Capsule().fill(theme.palette.accent))
            }
        }
        .padding(32)
    }
}

enum CameraAccess: Equatable {
    case allowed, undecided, refused, unavailable

    static var current: CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return .undecided
        default: return .refused
        }
    }

    static func request() async -> CameraAccess {
        await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .refused
    }
}

/// A square guide over the camera, edged in red for two seconds after reading a code that isn't the TV's.
private struct Viewfinder: View {
    let wrongCode: Bool

    @Environment(\.lumaRemoteTheme) private var theme

    var body: some View {
        VStack(spacing: 24) {
            RoundedRectangle(cornerRadius: theme.radii.surface, style: .continuous)
                .strokeBorder(wrongCode ? theme.palette.danger : Color.white, lineWidth: 3)
                .frame(width: 240, height: 240)
            Text(wrongCode ? "That isn't a LumaTV pairing code." : "Point the camera at the code on the TV.")
                .font(theme.font(.body, weight: .semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The camera's picture, reporting each QR payload it reads.
private struct CameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        if let camera = Camera(delegate: context.coordinator) {
            view.previewLayer.session = camera.session
            context.coordinator.camera = camera
            camera.start()
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.camera?.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer class above makes this cast always succeed.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        var camera: Camera?
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            // The delegate queue is the main queue.
            MainActor.assumeIsolated { found(codes) }
        }

        /// The camera reads a code many times a second; each distinct one counts once.
        private func found(_ codes: [String]) {
            guard let code = codes.first, code != lastCode else { return }
            lastCode = code
            onCode(code)
        }
    }

    /// A capture session on its own queue: starting and stopping block, so they stay off the main thread.
    final class Camera: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "LumaRemoteKit.camera")

        @MainActor
        init?(delegate: any AVCaptureMetadataOutputObjectsDelegate) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return nil }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return nil }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        func start() {
            queue.async { self.session.startRunning() }
        }

        func stop() {
            queue.async { self.session.stopRunning() }
        }
    }
}
#endif
