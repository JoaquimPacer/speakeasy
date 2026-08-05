@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct ContactQRCodeScannerScreen: View {
    @Environment(\.openURL) private var openURL

    @State private var phase: ScannerPhase = .rationale
    @State private var scannerErrorMessage: String?

    let contactName: String
    let onScan: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .rationale:
                rationaleView
            case .requestingPermission:
                ProgressView("Requesting camera access")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                scannerView
            case .permissionDenied:
                permissionDeniedView
            case .restricted:
                restrictedView
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Scan Safety Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
        .alert("Scanner unavailable", isPresented: scannerErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scannerErrorMessage ?? "The QR scanner could not start.")
        }
    }

    private var rationaleView: some View {
        VStack(spacing: 22) {
            Image(systemName: "viewfinder")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Scan \(contactName)’s signed code")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Camera access is used to read the verification QR code displayed on your contact’s device. Kithra passes the decoded code to the on-device identity check.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                continueToCamera()
            } label: {
                Label("Continue to Camera", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Requests camera permission if it has not already been granted")

            Text("After this scan succeeds, \(contactName) should also scan the signed code on your device.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var scannerView: some View {
        ZStack {
            ContactQRCodeCameraView(
                onCode: onScan,
                onFailure: { error in
                    scannerErrorMessage = error.localizedDescription
                }
            )
            .ignoresSafeArea(edges: .bottom)

            Color.black.opacity(0.28)
                .mask {
                    Rectangle()
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .frame(width: 280, height: 280)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 280, height: 280)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .accessibilityHidden(true)

            VStack {
                Spacer()

                Text("Center \(contactName)’s QR code in the frame")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 32)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("QR code scanner for \(contactName)")
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityHidden(true)

            Text("Camera access is off")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text("Allow Camera access in Settings to scan \(contactName)’s safety code. You can still compare all 60 digits manually without camera access.")
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Settings") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                openURL(settingsURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    private var restrictedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityHidden(true)

            Text("Camera access is restricted")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            Text("Camera access is restricted on this device. Compare the complete 60-digit safety number with \(contactName) instead.")
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    private var scannerErrorIsPresented: Binding<Bool> {
        Binding {
            scannerErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                scannerErrorMessage = nil
            }
        }
    }

    private func continueToCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            phase = .scanning
        case .notDetermined:
            phase = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    phase = granted ? .scanning : .permissionDenied
                }
            }
        case .denied:
            phase = .permissionDenied
        case .restricted:
            phase = .restricted
        @unknown default:
            phase = .restricted
        }
    }
}
private enum ScannerPhase {
    case rationale
    case requestingPermission
    case scanning
    case permissionDenied
    case restricted
}

private struct ContactQRCodeCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (Error) -> Void

    func makeUIViewController(context: Context) -> ContactQRCodeScannerViewController {
        ContactQRCodeScannerViewController(onCode: onCode, onFailure: onFailure)
    }

    func updateUIViewController(
        _ uiViewController: ContactQRCodeScannerViewController,
        context: Context
    ) {
        uiViewController.updateCallbacks(onCode: onCode, onFailure: onFailure)
    }

    static func dismantleUIViewController(
        _ uiViewController: ContactQRCodeScannerViewController,
        coordinator: Void
    ) {
        uiViewController.stopScanning()
    }
}

private final class ContactQRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.joaquimpacer.kithra.contact-qr-session")
    private let metadataQueue = DispatchQueue(label: "com.joaquimpacer.kithra.contact-qr-metadata")
    private let previewLayer: AVCaptureVideoPreviewLayer

    private var onCode: (String) -> Void
    private var onFailure: (Error) -> Void
    private var isConfigured = false
    private var didDeliverCode = false

    init(onCode: @escaping (String) -> Void, onFailure: @escaping (Error) -> Void) {
        self.onCode = onCode
        self.onFailure = onFailure
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    func updateCallbacks(
        onCode: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onCode = onCode
        self.onFailure = onFailure
    }

    func stopScanning() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func startScanning() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                }
                guard !self.captureSession.isRunning else {
                    return
                }
                self.captureSession.startRunning()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.onFailure(error)
                }
            }
        }
    }

    private func configureSession() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw ContactQRCodeScannerError.cameraPermissionUnavailable
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw ContactQRCodeScannerError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let metadataOutput = AVCaptureMetadataOutput()

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard captureSession.canAddInput(input) else {
            throw ContactQRCodeScannerError.cannotAddCameraInput
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(metadataOutput) else {
            throw ContactQRCodeScannerError.cannotAddMetadataOutput
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        metadataOutput.metadataObjectTypes = [.qr]
        isConfigured = true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didDeliverCode,
              let qrObject = metadataObjects.first(where: { $0.type == .qr }) as? AVMetadataMachineReadableCodeObject,
              let value = qrObject.stringValue,
              !value.isEmpty else {
            return
        }

        didDeliverCode = true
        stopScanning()
        DispatchQueue.main.async { [weak self] in
            self?.onCode(value)
        }
    }
}

private enum ContactQRCodeScannerError: LocalizedError {
    case cameraPermissionUnavailable
    case cameraUnavailable
    case cannotAddCameraInput
    case cannotAddMetadataOutput

    var errorDescription: String? {
        switch self {
        case .cameraPermissionUnavailable:
            return "Camera permission is unavailable."
        case .cameraUnavailable:
            return "No camera is available for QR scanning on this device."
        case .cannotAddCameraInput:
            return "The camera input could not be started."
        case .cannotAddMetadataOutput:
            return "The QR code reader could not be started."
        }
    }
}
