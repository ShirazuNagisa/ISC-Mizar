#if os(iOS)
import SwiftUI
import AVFoundation

/// 相机扫码。
///
/// # 只用 `AVCaptureMetadataOutput`，不引入第三方库
///
/// 二维码识别是系统自带的（`VNDetectBarcodesRequest` 与 `AVCaptureMetadataOutput`
/// 都能做），而"扫一个我们完全知道格式的码"这件事不需要任何额外能力。
/// 少一个依赖就少一处要跟着 iOS 版本更新、也少一处会读相机的东西。
///
/// # 这一层刻意很薄
///
/// 它只做一件事：把扫到的**第一段非空文本**交给上层。解析、校验、报错
/// 全部在 MizarKit 里（那里有测试）。相机是这个应用里唯一无法在
/// `swift test` 中覆盖的部分，因此它越小越好。
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    /// 只报一次。
    ///
    /// 二维码在取景框里会停留好几帧，不去重的话一次扫码会触发几十次配对
    /// 请求 —— 而配对码是**一次性**的：第二次请求会失败，用户于是看到
    /// 一句"配对码不正确"出现在一次成功的配对之后。
    private let hasScanned = ScanLatch()

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = { text in
            guard hasScanned.take() else { return }
            onScan(text)
        }
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

/// 一次性闸门。
final class ScanLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// 返回 true 表示"这是第一次"。
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// 相机的起停队列。
    ///
    /// 单独一条而不是 `.global()`：相机起停是串行且低频的，而全局并发队列
    /// 上可能同时排着别的东西（图片解码、网络回调）—— 让相机的启动排在
    /// 它们后面会让取景框明显慢一拍。
    private let cameraQueue = DispatchQueue(label: "app.isc.mizar.camera")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    /// 起停放到专用队列。
    ///
    /// `startRunning()` 会**阻塞**几百毫秒（它要等硬件就绪），Apple 明确
    /// 建议不要在主的队列上调用它 —— 在主的队列上做会让界面明显卡一下，
    /// 而那个卡顿恰好发生在用户举起手机对准二维码的那一刻。
    ///
    /// `AVCaptureSession` 没有标注 `Sendable`，因此这里用
    /// `nonisolated(unsafe)` 显式承担跨线程的责任。依据是：
    /// **配置只在主线程做（viewDidLoad），起停只在这条队列上做，两者不重叠**，
    /// 而 start/stop 本身是 Apple 文档里允许在任意队列调用的操作。
    /// 把这条约定写在抑制的旁边，而不是给整个控制器盖一个 `@unchecked`。
    private func startSession() {
        nonisolated(unsafe) let session = self.session
        cameraQueue.async { session.startRunning() }
    }

    private func stopSession() {
        nonisolated(unsafe) let session = self.session
        cameraQueue.async { session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // 必须在 addOutput **之后**设置：在此之前 types 是空的，
        // 赋任何值都会被静默忽略 —— 表现是"相机开着但永远扫不到东西"。
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    private func showUnavailable() {
        // 没有相机权限，或者这个设备没有摄像头（模拟器）。
        //
        // 说清楚**下一步该做什么**：用户会以为应用坏了，而实际上
        // 手输那条路一直可用。
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .callout)
        label.text = "无法使用相机。请检查系统设置里的相机权限，或者改用「手动输入」六位配对码。"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let text = object.stringValue, !text.isEmpty else { return }
        onScan?(text)
    }
}
#endif
