import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import Combine
import AppKit

// 后台转换引擎 Actor
actor ImageConversionActor {
    // 执行图片转 HEIC
    func convertImage(url: URL, deleteOriginal: Bool, skipNegative: Bool) async -> Int64 {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        
        let destinationURL = url.deletingPathExtension().appendingPathExtension("heic")
        if url.pathExtension.lowercased() == "heic" { return 0 }
        
        // 创建图片源和目标
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return 0
        }
        
        // 无损转换
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, nil)
        
        // 最终执行写入硬盘
        if CGImageDestinationFinalize(destination) {
            let oldSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let newSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            
            // 跳过负优化
            // 如果转换后图片比原始更大，会保留原始图片
            if skipNegative && newSize >= oldSize {
                try? FileManager.default.removeItem(at: destinationURL)
                return 0
            }
            
            // 删除原始文件
            if deleteOriginal {
                // 移到废纸篓
                Task { @MainActor in
                    NSWorkspace.shared.recycle([url]) { (newURLs, error) in
                        if let error = error {
                            print("移动到废纸篓失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return oldSize - newSize
        }
        return 0
    }
}

@MainActor
class ImageConverterViewModel: ObservableObject {
    // 总文件数
    @Published var totalCount = 0
    // 已处理文件数
    @Published var processedCount = 0
    // 总节省空间
    @Published var savedSpace: Int64 = 0
    // 转换状态
    @Published var isProcessing = false
    // 扫描文件夹状态
    @Published var isScanning = false
    // 当前正在处理的文件名称
    @Published var lastFileName = ""
    // 待处理的文件列表
    @Published var allResolvedFiles: [URL] = []
    
    private let conversionActor = ImageConversionActor()

    // 将多个文件夹或者文件处理成单一的 URL 列表
    func prepareItems(_ urls: [URL]) async {
        self.processedCount = 0
        self.savedSpace = 0
        self.lastFileName = ""
        self.allResolvedFiles = []
        self.totalCount = 0
        isScanning = true

        // 支持转换的文件类型
        let exts = ["jpg", "jpeg", "png", "tiff", "bmp", "webp"]
        
        // 在后台任务中进行文件扫描
        let resolvedFiles = await Task.detached(priority: .userInitiated) {
            var files: [URL] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        // 递归扫描所有子文件
                        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        while let fileURL = enumerator?.nextObject() as? URL {
                            if exts.contains(fileURL.pathExtension.lowercased()) {
                                files.append(fileURL)
                            }
                        }
                    } else if exts.contains(url.pathExtension.lowercased()) {
                        files.append(url)
                    }
                }
            }
            // 移除重复
            return Array(Set(files))
        }.value
        
        self.allResolvedFiles = resolvedFiles
        self.totalCount = resolvedFiles.count
        self.isScanning = false
    }

    // 批量转换
    func startConversion(deleteOriginal: Bool, skipNegative: Bool) async {
        guard totalCount > 0 else { return }
        processedCount = 0
        savedSpace = 0
        withAnimation(.spring()) { isProcessing = true }
        
        let filesToProcess = self.allResolvedFiles
        // 获取 CPU 核心数
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        var lastUIUpdateTime = Date.distantPast
        
        // 并发控制
        await withTaskGroup(of: (String, Int64).self) { group in
            for (index, fileURL) in filesToProcess.enumerated() {
                // 并发节流
                if index >= cpuCount {
                    if let result = await group.next() {
                        updateProgress(result: result, lastTime: &lastUIUpdateTime, total: filesToProcess.count)
                    }
                }

                // 将转换任务提交给 Actor 执行
                group.addTask {
                    let saving = await self.conversionActor.convertImage(url: fileURL, deleteOriginal: deleteOriginal, skipNegative: skipNegative)
                    return (fileURL.lastPathComponent, saving)
                }
            }
            
            // 处理剩余未完成的任务
            while let result = await group.next() {
                updateProgress(result: result, lastTime: &lastUIUpdateTime, total: filesToProcess.count)
            }
        }
        withAnimation(.spring()) { isProcessing = false }
    }
    
    // 更新进度
    private func updateProgress(result: (String, Int64), lastTime: inout Date, total: Int) {
        processedCount += 1
        lastFileName = result.0
        savedSpace += result.1
        let now = Date()
        if now.timeIntervalSince(lastTime) > 0.1 || processedCount == total {
            lastTime = now
            objectWillChange.send()
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ImageConverterViewModel()
    @State private var deleteOriginal = false
    @State private var skipNegative = true // 默认开启跳过负优化
    @State private var isTargeted = false
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // 顶部标题
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.blue)
                        Text("app_title")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 10)
                
                // 中间内容区
                VStack {
                    if viewModel.totalCount == 0 {
                        welcomeView
                    } else {
                        progressView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // 底部栏
                VStack(spacing: 0) {
                    Divider().opacity(0.6)
                    
                    HStack(alignment: .center) {
                        // 左下角齿轮图标
                        Button(action: { showSettings.toggle() }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20)) // 稍微调大图标
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSettings, arrowEdge: .top) {
                            settingsPopoverView
                        }
                        .disabled(viewModel.isProcessing)
                        
                        Spacer()
                        
                        // 转换按钮
                        Button(action: {
                            Task { await viewModel.startConversion(deleteOriginal: deleteOriginal, skipNegative: skipNegative) }
                        }) {
                            ZStack {
                                if viewModel.isProcessing {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small).brightness(1)
                                        Text("status_converting")
                                    }
                                } else {
                                    Text("btn_start")
                                }
                            }
                            .fontWeight(.bold)
                            .frame(width: 110, height: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(viewModel.totalCount == 0 || viewModel.isProcessing)
                    }
                    .padding(.horizontal, 25)
                    .padding(.vertical, 25)
                }
            }
        }
        .frame(width: 380, height: 500)
        // 整个窗口都支持拖拽
        .onDrop(of: [.url, .fileURL], isTargeted: $isTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await loadURL(from: provider) { urls.append(url) }
                }
                if !urls.isEmpty { await viewModel.prepareItems(urls) }
            }
            return true
        }
    }
    
    // 设置界面
    private var settingsPopoverView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("setting_delete_original", isOn: $deleteOriginal)
                .font(.system(size: 15, weight: .medium))
            
            Toggle("setting_skip_negative", isOn: $skipNegative)
                .font(.system(size: 15, weight: .medium))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 25)
    }
    
    private var welcomeView: some View {
        VStack(spacing: 25) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.04)).frame(width: 140, height: 140)
                Image(systemName: "plus").font(.system(size: 44, weight: .thin)).foregroundColor(.blue)
            }

            VStack(spacing: 8) {
                Text(viewModel.isScanning ? "status_scanning" : "drop_hint").font(.system(size: 18, weight: .semibold, design: .rounded))
            }
        }
    }
    
    private var progressView: some View {
        VStack(spacing: 40) {
            // 环形进度条
            ZStack {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: 10)
                Circle().trim(from: 0, to: viewModel.totalCount > 0 ? min(1.0, Double(viewModel.processedCount) / Double(viewModel.totalCount)) : 0)
                    .stroke(LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 4) {
                    Text("\(min(100, Int((Double(viewModel.processedCount) / Double(max(1, viewModel.totalCount))) * 100)))%").font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    Text("\(viewModel.processedCount) / \(viewModel.totalCount)").font(.system(size: 13, design: .monospaced)).foregroundColor(.secondary)
                }
            }.frame(width: 170, height: 170)
            
            // 空间节省统计
            VStack(spacing: 2) {
                Text(formatBytes(viewModel.savedSpace)).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()).foregroundColor(.green)
                Text("label_saved_space").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            }
        }
    }

    // 将字节数转换为易读的格式
    private func formatBytes(_ bytes: Int64) -> String {
        let val = max(0, bytes)
        if val == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: val)
    }

    // 处理拖拽进入的 NSItemProvider 转换为 URL
    private func loadURL(from provider: NSItemProvider) async -> URL? {
        return await withCheckedContinuation { continuation in
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else if let url = item as? URL { continuation.resume(returning: url) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }
    }
}
