import SwiftUI
@preconcurrency import AVFoundation

struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    let receive: (String) throws -> Void
    var body: some View {
        NavigationStack {
            ZStack {
                CameraReader { result in
                    switch result {
                    case .success(let value):
                        do { try receive(value); dismiss() }
                        catch { self.error = error.localizedDescription }
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }
                if let error {
                    Text(error).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .navigationTitle(L("Scan pairing QR", "扫描配对二维码")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } } }
        }
    }
}

private struct CameraReader: UIViewControllerRepresentable {
    let receive: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> PairingCamera { PairingCamera(receive: receive) }
    func updateUIViewController(_ controller: PairingCamera, context: Context) {}
}

private final class PairingCamera: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "DRP.pairing.camera")
    private let receive: (Result<String, Error>) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastValue: String?
    init(receive: @escaping (Result<String, Error>) -> Void) { self.receive = receive; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if preview != nil {
            let session = capture
            queue.async { session.startRunning() }
            return
        }
        Task { [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.viewIfLoaded?.window != nil else { return }
            guard allowed else { receive(.failure(PortalError.message(L("Allow camera access in Settings, or paste a pairing link instead.", "请在设置中允许相机访问，或粘贴配对链接。")))); return }
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else { throw PortalError.message(L("Camera unavailable. Paste a pairing link instead.", "相机不可用，请粘贴配对链接。")) }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                guard capture.canAddInput(input), capture.canAddOutput(output) else { throw APIError.invalidResponse }
                capture.addInput(input); capture.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                let layer = AVCaptureVideoPreviewLayer(session: capture)
                layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer; layer.frame = view.bounds
                let session = capture
                queue.async { session.startRunning() }
            } catch { receive(.failure(error)) }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = capture
        queue.async { session.stopRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value != lastValue else { return }
        lastValue = value; receive(.success(value))
    }
}
