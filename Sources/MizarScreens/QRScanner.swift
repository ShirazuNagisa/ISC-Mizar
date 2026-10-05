#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import MizarUI

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

        // 整段配置放进一次 begin/commit。
        //
        // # 为什么要包起来
        //
        // 不包的话，`addInput`、`addOutput`、`sessionPreset`、
        // `metadataObjectTypes` 每一步都会**各自**触发一次会话重配置 ——
        // 而重配置要重新协商分辨率与帧率，是这条路径上最贵的一段。
        // 用户感知到的是"举起手机之后取景框要等一下才出来"，而这段等待
        // 恰好发生在他对准二维码的时候。
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 分辨率降到 720p。
        //
        // 默认档位是 `.high`（多数机型是 1080p，Pro 上更高），而这一路
        // **只需要看清一个二维码**：每一帧都要交给元数据检测器扫一遍，
        // 像素多一倍，检测就慢一截、也费一截电。720p 下二维码的内置
        // 纠错与 1080p 没有可感知的差别。
        //
        // 先问 `canSetSessionPreset` 再设：设了不支持的档位会**抛异常**
        // 而不是返回错误。
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
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
        //
        // 只留 `.qr`：枚举里每多一个类型，检测器每帧就要多跑一遍。
        output.metadataObjectTypes = [.qr]
        // 只看画面中央那一块。
        //
        // 苹果的文档说得很直接："Specifying a rectOfInterest may improve
        // detection performance" —— 检测面积小了，同样的时间预算里能扫的
        // 帧就多了。取居中的正方形还顺带绕开了一个坑：这个矩形的坐标系
        // 是**传感器方向**（横屏）的，非居中的矩形在竖屏预览里会落到
        // 意想不到的位置上；居中的矩形在两种方向下都是居中。
        output.rectOfInterest = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    private func showUnavailable() {
        // 相机用不了。两种原因的**出路完全不同**，因此要分开说：
        //
        //	权限被拒（或被家长控制 / MDM 限制）→ 只有系统设置里能改
        //	这台设备没有摄像头（模拟器就是这样）→ 没有可改的，换粘贴链接
        //
        // 合成一句"请检查相机权限"的后果是：在模拟器上跑的人跑去设置里
        // 找一个根本不存在的开关，而真正该做的是改用粘贴配对链接。
        let cameraDenied = {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: return true
            default: return false
            }
        }()

        let message = UILabel()
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .callout)
        message.text = cameraDenied
            ? tr("Mizar 没有相机权限，扫不了码。在系统设置里打开相机，或者改用「粘贴配对链接」。",
                 "Mizar has no camera access, so it cannot scan. Turn Camera on in Settings, or paste the pairing link instead.")
            : tr("这台设备上没有可用的摄像头（模拟器就是这样）。请改用「粘贴配对链接」。",
                 "There is no usable camera on this device (the simulator is one). Paste the pairing link instead.")

        let stack = UIStackView(arrangedSubviews: [message])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        if cameraDenied {
            // 一个**真的走得通**的出路，而不是一句"请去设置里打开"。
            //
            // 系统只会问一次相机权限：再调 `requestAccess` 不会弹任何
            // 东西，只是立刻回 false。因此这里除了打开系统设置没有别的
            // 选择 —— 而按钮的标题必须与它真正会做的事一致，所以它叫
            // "去系统设置开启"，不叫"重试"。一个写着"重试"却什么都不弹
            // 的按钮会让用户反复点它。
            var config = UIButton.Configuration.filled()
            config.title = tr("去系统设置开启", "Open Settings")
            let button = UIButton(configuration: config)
            button.addTarget(self, action: #selector(openSystemSettings), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
        ])
    }

    /// 打开本应用在系统设置里的那一页。
    ///
    /// 相机开关就在那一页上。（局域网**不在** —— 它在「隐私与安全性 →
    /// 本地网络」下，没有可以直达的链接。因此这个按钮只用于相机。）
    @objc private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
