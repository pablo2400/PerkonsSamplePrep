import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

let maxTotalBytes = 256_000
let targetSampleRate = 48_000.0
let targetChannels: AVAudioChannelCount = 1
let bytesPerFrame = 2

struct SourceSample {
    let url: URL
    let name: String
    let duration: Double
}

struct ConversionSet: Codable {
    let id: String
    let createdAt: Date
    var title: String?
    let sourceNames: [String]
    let outputBytes: [Int]
    let durations: [Double]
    let folderPath: String

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? sourceNames.joined(separator: ", ") : trimmed
    }
}

enum PlaybackList {
    case input
    case output
}

final class ConverterState: @unchecked Sendable {
    var sourceDone = false
}

@MainActor
final class SampleTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var dropHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:
            onSpace?()
        case 51, 117:
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        onFiles?(items)
        return true
    }
}

@MainActor
final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 3 : 1
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        onFiles?(items)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let fileTable = SampleTableView()
    private let outputTable = SampleTableView()
    private let historyTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Add 3 WAV files.")
    private let addButton = NSButton(title: "Add WAV...", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let convertButton = NSButton(title: "Convert and Save...", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let openHistoryButton = NSButton(title: "Open History Folder", target: nil, action: nil)
    private let copyHistoryButton = NSButton(title: "Copy Selected Set...", target: nil, action: nil)
    private let renameHistoryButton = NSButton(title: "Rename Selected...", target: nil, action: nil)
    private let trimCheckbox = NSButton(checkboxWithTitle: "Auto-trim to 256 KB total", target: nil, action: nil)

    private var samples: [SourceSample] = []
    private var outputSamples: [SourceSample] = []
    private var history: [ConversionSet] = []
    private var player: AVAudioPlayer?
    private var playingList: PlaybackList?
    private var playingIndex: Int?
    private var isRefreshingPlaybackTables = false
    private var renamePanel: NSPanel?
    private let appSupport: URL
    private let historyRoot: URL

    override init() {
        let fm = FileManager.default
        appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerkonsSamplePrep", isDirectory: true)
        historyRoot = appSupport.appendingPathComponent("History", isDirectory: true)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createFolders()
        loadHistory()
        buildWindow()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PERKONS HD-01 Sample Prep"
        window.minSize = NSSize(width: 820, height: 680)
        window.setContentSize(NSSize(width: 820, height: 680))
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 4, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let formatInfo = NSTextField(labelWithString: "PERKONS user samples load only on Voice 4 / Algorithm 3; output is always 3 files: mono 16-bit WAV, 48 kHz, max 256 KB total.")
        formatInfo.textColor = .secondaryLabelColor
        formatInfo.font = .systemFont(ofSize: 12)
        formatInfo.lineBreakMode = .byTruncatingTail

        let drop = DropView()
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 132).isActive = true
        drop.onFiles = { [weak self] urls in self?.addFiles(urls, allowReplacement: true) }
        let dropLabel = NSTextField(labelWithString: "Drop WAV files here")
        dropLabel.font = .systemFont(ofSize: 18, weight: .medium)
        dropLabel.alignment = .center
        drop.addSubview(dropLabel)
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dropLabel.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: drop.centerYAnchor)
        ])

        configureFileTable()
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        fileScroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        trimCheckbox.state = .on

        let controls = NSStackView(views: [addButton, removeButton, previewButton, convertButton, clearButton, trimCheckbox])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY
        addButton.target = self
        addButton.action = #selector(addFromPanel)
        removeButton.target = self
        removeButton.action = #selector(removeSelectedFile)
        previewButton.target = self
        previewButton.action = #selector(previewSelectedFile)
        convertButton.target = self
        convertButton.action = #selector(convertAndSave)
        clearButton.target = self
        clearButton.action = #selector(clearFiles)

        statusLabel.textColor = .secondaryLabelColor

        let outputTitle = NSTextField(labelWithString: "Converted Output")
        outputTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        configureOutputTable()
        let outputScroll = NSScrollView()
        outputScroll.documentView = outputTable
        outputScroll.hasVerticalScroller = true
        outputScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let historyTitle = NSTextField(labelWithString: "History")
        historyTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        configureHistoryTable()
        let historyScroll = NSScrollView()
        historyScroll.documentView = historyTable
        historyScroll.hasVerticalScroller = true

        let historyControls = NSStackView(views: [copyHistoryButton, renameHistoryButton, openHistoryButton])
        historyControls.orientation = .horizontal
        historyControls.spacing = 10
        copyHistoryButton.target = self
        copyHistoryButton.action = #selector(copySelectedHistory)
        renameHistoryButton.target = self
        renameHistoryButton.action = #selector(renameSelectedHistory)
        openHistoryButton.target = self
        openHistoryButton.action = #selector(openHistoryFolder)

        root.addArrangedSubview(formatInfo)
        root.addArrangedSubview(drop)
        root.addArrangedSubview(fileScroll)
        root.addArrangedSubview(controls)
        root.addArrangedSubview(statusLabel)
        root.addArrangedSubview(outputTitle)
        root.addArrangedSubview(outputScroll)
        root.addArrangedSubview(historyTitle)
        root.addArrangedSubview(historyScroll)
        root.addArrangedSubview(historyControls)

        let content = NSView()
        window.contentView = content
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        updateButtons()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureFileTable() {
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.headerView = nil
        fileTable.allowsMultipleSelection = false
        fileTable.onSpace = { [weak self] in self?.previewSelectedFile() }
        fileTable.onDelete = { [weak self] in self?.removeSelectedFile() }
        fileTable.onFiles = { [weak self] urls in self?.addFiles(urls, allowReplacement: true) }
        fileTable.addTableColumn(column("play", "", width: 34))
        fileTable.addTableColumn(column("file", "File", width: 520))
        fileTable.addTableColumn(column("duration", "Duration", width: 120))
        fileTable.addTableColumn(column("output", "Output", width: 80))
    }

    private func configureOutputTable() {
        outputTable.dataSource = self
        outputTable.delegate = self
        outputTable.headerView = nil
        outputTable.allowsMultipleSelection = false
        outputTable.onSpace = { [weak self] in self?.previewSelectedOutput() }
        outputTable.addTableColumn(column("play", "", width: 34))
        outputTable.addTableColumn(column("file", "File", width: 520))
        outputTable.addTableColumn(column("duration", "Duration", width: 120))
        outputTable.addTableColumn(column("size", "Size", width: 90))
    }

    private func configureHistoryTable() {
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.addTableColumn(column("date", "Date", width: 170))
        historyTable.addTableColumn(column("name", "Name", width: 420))
        historyTable.addTableColumn(column("size", "Size", width: 90))
    }

    private func column(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        return column
    }

    @objc private func addFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose WAV files. The set must contain exactly 3 files before conversion."
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls, allowReplacement: true)
    }

    private func addFiles(_ urls: [URL], allowReplacement: Bool = false) {
        let wavs = urls.filter { $0.pathExtension.lowercased() == "wav" }
        guard !wavs.isEmpty else {
            setStatus("No WAV files found.", error: true)
            return
        }
        guard wavs.count <= 3 else {
            setStatus("The set can contain only 3 WAV files.", error: true)
            return
        }

        guard samples.count + wavs.count <= 3 else {
            guard allowReplacement else {
                setStatus("The set can contain only 3 WAV files. Remove one before adding another.", error: true)
                return
            }
            replaceInputFiles(with: wavs)
            return
        }

        do {
            let newSamples = try wavs.map { url in
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.fileFormat.sampleRate
                return SourceSample(url: url, name: url.lastPathComponent, duration: duration)
            }
            samples.append(contentsOf: newSamples)
            fileTable.reloadData()
            if samples.count == 3 {
                setStatus("Ready. Files will be written as 1.wav, 2.wav, 3.wav.", error: false)
            } else {
                setStatus("\(samples.count)/3 files added.", error: false)
            }
        } catch {
            setStatus("Could not read WAV files: \(error.localizedDescription)", error: true)
        }
        updateButtons()
    }

    private func replaceInputFiles(with urls: [URL]) {
        do {
            let newSamples = try urls.map { url in
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.fileFormat.sampleRate
                return SourceSample(url: url, name: url.lastPathComponent, duration: duration)
            }

            if newSamples.count == 1, fileTable.selectedRow >= 0, fileTable.selectedRow < samples.count {
                let row = fileTable.selectedRow
                guard confirmInputReplacement(message: "Replace selected sample \"\(samples[row].name)\" with \"\(newSamples[0].name)\"?") else {
                    setStatus("Drop cancelled.", error: false)
                    return
                }
                stopPreview()
                samples[row] = newSamples[0]
                fileTable.reloadData()
                fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                setStatus("Replaced selected sample.", error: false)
            } else {
                guard confirmInputReplacement(message: "There are not enough empty slots. Replace the current input list with the dropped WAV files?") else {
                    setStatus("Drop cancelled.", error: false)
                    return
                }
                stopPreview()
                samples = newSamples
                fileTable.reloadData()
                setStatus("\(samples.count)/3 files added.", error: samples.count != 3)
            }
            updateButtons()
        } catch {
            setStatus("Could not read WAV files: \(error.localizedDescription)", error: true)
        }
    }

    private func confirmInputReplacement(message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace input sample?"
        alert.informativeText = message
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func clearFiles() {
        stopPreview()
        samples = []
        fileTable.reloadData()
        setStatus("Add 3 WAV files.", error: false)
        updateButtons()
    }

    @objc private func removeSelectedFile() {
        let row = fileTable.selectedRow
        guard row >= 0 && row < samples.count else { return }
        stopPreview()
        let removed = samples.remove(at: row)
        fileTable.reloadData()
        if !samples.isEmpty {
            fileTable.selectRowIndexes(IndexSet(integer: min(row, samples.count - 1)), byExtendingSelection: false)
        }
        setStatus("Removed \(removed.name). \(samples.count)/3 files added.", error: false)
        updateButtons()
    }

    private func stopPreview(reload: Bool = true) {
        player?.stop()
        player = nil
        playingList = nil
        playingIndex = nil
        if reload {
            reloadPlaybackTables()
        }
    }

    @objc private func convertAndSave() {
        guard samples.count == 3 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Choose the folder where 1.wav, 2.wav and 3.wav will be written."
        guard panel.runModal() == .OK, let outputFolder = panel.url else { return }
        let outputURLs = (1...3).map { outputFolder.appendingPathComponent("\($0).wav") }
        guard confirmOverwriteIfNeeded(outputURLs) else { return }

        do {
            let result = try convert(samples: samples, outputFolder: outputFolder, allowTrim: trimCheckbox.state == .on)
            outputSamples = (0..<3).map { index in
                let url = outputFolder.appendingPathComponent("\(index + 1).wav")
                return SourceSample(url: url, name: url.lastPathComponent, duration: result.durations[index])
            }
            outputTable.reloadData()
            saveToHistory(result.folder, originalOutput: outputFolder, durations: result.durations, bytes: result.bytes)
            loadHistory()
            historyTable.reloadData()
            let total = result.bytes.reduce(0, +)
            setStatus("Saved 3 files. Total: \(formatBytes(total)).", error: false)
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func convert(samples: [SourceSample], outputFolder: URL, allowTrim: Bool) throws -> (folder: URL, durations: [Double], bytes: [Int]) {
        let availableAudioBytes = maxTotalBytes - (44 * 3)
        let totalDuration = samples.map(\.duration).reduce(0, +)
        let maxDuration = Double(availableAudioBytes) / Double(Int(targetSampleRate) * bytesPerFrame)
        let scale = totalDuration > maxDuration ? maxDuration / totalDuration : 1.0

        if scale < 1.0 && !allowTrim {
            throw NSError(domain: "PerkonsSamplePrep", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Converted files would exceed 256 KB. Enable auto-trim or use shorter samples."
            ])
        }

        var durations: [Double] = []
        var bytes: [Int] = []
        for index in 0..<3 {
            let duration = max(0.01, samples[index].duration * min(scale, 1.0))
            let output = outputFolder.appendingPathComponent("\(index + 1).wav")
            try convertOne(input: samples[index].url, output: output, maxDuration: duration)
            durations.append(duration)
            bytes.append(try fileSize(output))
        }

        let total = bytes.reduce(0, +)
        if total > maxTotalBytes {
            throw NSError(domain: "PerkonsSamplePrep", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Output is \(formatBytes(total)), above the 256 KB PERKONS limit."
            ])
        }
        return (outputFolder, durations, bytes)
    }

    private func convertOne(input: URL, output: URL, maxDuration: Double) throws {
        let sourceFile = try AVAudioFile(forReading: input)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: targetChannels, interleaved: false) else {
            throw NSError(domain: "PerkonsSamplePrep", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create output audio format."])
        }
        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: outFormat) else {
            throw NSError(domain: "PerkonsSamplePrep", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter."])
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let outputCapacity: AVAudioFrameCount = 4096
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputCapacity)!
        let inputCapacity: AVAudioFrameCount = 4096
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFile.processingFormat, frameCapacity: inputCapacity)!
        let maxFrames = AVAudioFramePosition(maxDuration * targetSampleRate)
        var written: AVAudioFramePosition = 0
        var pcm = Data()
        pcm.reserveCapacity(Int(maxFrames) * bytesPerFrame)
        let state = ConverterState()

        while written < maxFrames {
            let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
                if state.sourceDone {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try sourceFile.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 {
                        state.sourceDone = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    state.sourceDone = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if outputBuffer.frameLength > 0 {
                let remaining = AVAudioFrameCount(maxFrames - written)
                if outputBuffer.frameLength > remaining {
                    outputBuffer.frameLength = remaining
                }
                appendInt16PCM(from: outputBuffer, to: &pcm)
                written += AVAudioFramePosition(outputBuffer.frameLength)
            }

            if status == .endOfStream || state.sourceDone || outputBuffer.frameLength == 0 {
                break
            }
        }
        try writeWAV(pcmData: pcm, to: output)
    }

    private func appendInt16PCM(from buffer: AVAudioPCMBuffer, to data: inout Data) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        for index in 0..<Int(buffer.frameLength) {
            let clamped = min(1.0, max(-1.0, channel[index]))
            let scaled = clamped < 0 ? clamped * 32768.0 : clamped * 32767.0
            var sample = Int16(scaled).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
    }

    private func writeWAV(pcmData: Data, to url: URL) throws {
        var data = Data()
        let sampleRate = UInt32(targetSampleRate)
        let channelCount = UInt16(targetChannels)
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36 + pcmData.count)

        data.appendASCII("RIFF")
        data.appendLE(riffSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channelCount)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.appendASCII("data")
        data.appendLE(dataSize)
        data.append(pcmData)
        try data.write(to: url)
    }

    private func saveToHistory(_ folder: URL, originalOutput: URL, durations: [Double], bytes: [Int]) {
        let id = historyID()
        let destination = historyRoot.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for index in 1...3 {
                let src = folder.appendingPathComponent("\(index).wav")
                let dst = destination.appendingPathComponent("\(index).wav")
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            }
            let manifest = ConversionSet(
                id: id,
                createdAt: Date(),
                title: samples.map(\.name).joined(separator: ", "),
                sourceNames: samples.map(\.name),
                outputBytes: bytes,
                durations: durations,
                folderPath: destination.path
            )
            let data = try JSONEncoder.pretty.encode(manifest)
            try data.write(to: destination.appendingPathComponent("manifest.json"))
        } catch {
            setStatus("Saved output, but history failed: \(error.localizedDescription)", error: true)
        }
    }

    private func loadHistory() {
        createFolders()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: historyRoot, includingPropertiesForKeys: nil) else {
            history = []
            return
        }
        history = dirs.compactMap { dir in
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? JSONDecoder.default.decode(ConversionSet.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @objc private func copySelectedHistory() {
        let row = historyTable.selectedRow
        guard row >= 0 && row < history.count else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let destinationURLs = (1...3).map { destination.appendingPathComponent("\($0).wav") }
        guard confirmOverwriteIfNeeded(destinationURLs) else { return }

        do {
            let source = URL(fileURLWithPath: history[row].folderPath)
            for index in 1...3 {
                let src = source.appendingPathComponent("\(index).wav")
                let dst = destination.appendingPathComponent("\(index).wav")
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            }
            setStatus("Copied selected history set.", error: false)
        } catch {
            setStatus("Could not copy history set: \(error.localizedDescription)", error: true)
        }
    }

    private func confirmOverwriteIfNeeded(_ urls: [URL]) -> Bool {
        var replaceAll = false

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if replaceAll { continue }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\"\(url.lastPathComponent)\" already exists."
            alert.informativeText = "Do you want to replace the existing file?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to all"

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                setStatus("Save cancelled.", error: false)
                return false
            }

            if alert.suppressionButton?.state == .on {
                replaceAll = true
            }
        }

        return true
    }

    @objc private func renameSelectedHistory() {
        let row = historyTable.selectedRow
        guard row >= 0 && row < history.count else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Rename History Set"
        panel.isReleasedWhenClosed = false

        let content = NSView()
        panel.contentView = content

        let label = NSTextField(labelWithString: "Name")
        let input = NSTextField()
        input.stringValue = history[row].displayTitle

        let saveButton = NSButton(title: "Save", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        [label, input, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            input.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        cancelButton.target = self
        cancelButton.action = #selector(cancelRenamePanel(_:))
        saveButton.target = self
        saveButton.action = #selector(saveRenamePanel(_:))
        saveButton.tag = row
        panel.initialFirstResponder = input
        panel.makeFirstResponder(input)
        renamePanel = panel
        window.beginSheet(panel)
    }

    @objc private func cancelRenamePanel(_ sender: NSButton) {
        guard let panel = sender.window else { return }
        window.endSheet(panel)
        renamePanel = nil
    }

    @objc private func saveRenamePanel(_ sender: NSButton) {
        guard let panel = sender.window,
              let content = panel.contentView,
              let input = content.subviews.compactMap({ $0 as? NSTextField }).last else {
            return
        }
        let row = sender.tag
        guard row >= 0 && row < history.count else {
            window.endSheet(panel)
            return
        }
        history[row].title = input.stringValue
        saveHistoryManifest(history[row])
        historyTable.reloadData()
        setStatus("History set renamed.", error: false)
        window.endSheet(panel)
        renamePanel = nil
    }

    private func saveHistoryManifest(_ set: ConversionSet) {
        do {
            let url = URL(fileURLWithPath: set.folderPath).appendingPathComponent("manifest.json")
            let data = try JSONEncoder.pretty.encode(set)
            try data.write(to: url)
        } catch {
            setStatus("Could not rename history set: \(error.localizedDescription)", error: true)
        }
    }

    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(historyRoot)
    }

    @objc private func previewSelectedOutput() {
        preview(table: outputTable, list: .output, samples: outputSamples, toggleCurrent: true)
    }

    private func createFolders() {
        try? FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
    }

    private func updateButtons() {
        addButton.isEnabled = samples.count < 3
        removeButton.isEnabled = fileTable.selectedRow >= 0 && fileTable.selectedRow < samples.count
        previewButton.isEnabled = fileTable.selectedRow >= 0 && fileTable.selectedRow < samples.count
        convertButton.isEnabled = samples.count == 3
        clearButton.isEnabled = !samples.isEmpty
        copyHistoryButton.isEnabled = !history.isEmpty
        renameHistoryButton.isEnabled = historyTable.selectedRow >= 0 && historyTable.selectedRow < history.count
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == fileTable {
            return samples.count
        }
        if tableView == outputTable {
            return outputSamples.count
        }
        return history.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        if tableView == fileTable {
            let sample = samples[row]
            switch tableColumn?.identifier.rawValue {
            case "play": text.stringValue = playIcon(for: .input, row: row)
            case "duration": text.stringValue = String(format: "%.2fs", sample.duration)
            case "output": text.stringValue = "\(row + 1).wav"
            default: text.stringValue = sample.name
            }
        } else if tableView == outputTable {
            let sample = outputSamples[row]
            switch tableColumn?.identifier.rawValue {
            case "play": text.stringValue = playIcon(for: .output, row: row)
            case "duration": text.stringValue = String(format: "%.2fs", sample.duration)
            case "size":
                let bytes = (try? fileSize(sample.url)) ?? 0
                text.stringValue = formatBytes(bytes)
            default: text.stringValue = sample.name
            }
        } else {
            let item = history[row]
            switch tableColumn?.identifier.rawValue {
            case "date": text.stringValue = DateFormatter.history.string(from: item.createdAt)
            case "size": text.stringValue = formatBytes(item.outputBytes.reduce(0, +))
            default: text.stringValue = item.displayTitle
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isRefreshingPlaybackTables {
            updateButtons()
            return
        }
        guard let table = notification.object as? NSTableView else {
            updateButtons()
            return
        }
        if player?.isPlaying == true {
            if table == fileTable {
                preview(table: fileTable, list: .input, samples: samples, toggleCurrent: false)
            } else if table == outputTable {
                preview(table: outputTable, list: .output, samples: outputSamples, toggleCurrent: false)
            }
        } else if table == historyTable {
            loadSelectedHistoryIntoOutput()
        }
        updateButtons()
    }

    private func loadSelectedHistoryIntoOutput() {
        let row = historyTable.selectedRow
        guard row >= 0 && row < history.count else { return }
        stopPreview()
        let set = history[row]
        let folder = URL(fileURLWithPath: set.folderPath)
        outputSamples = (0..<3).compactMap { index in
            let url = folder.appendingPathComponent("\(index + 1).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let duration = index < set.durations.count ? set.durations[index] : wavDuration(url)
            return SourceSample(url: url, name: url.lastPathComponent, duration: duration)
        }
        outputTable.reloadData()
        setStatus("Loaded \(set.displayTitle) into Converted Output.", error: outputSamples.count != 3)
    }

    private func wavDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    @objc private func previewSelectedFile() {
        preview(table: fileTable, list: .input, samples: samples, toggleCurrent: true)
    }

    private func preview(table: NSTableView, list: PlaybackList, samples: [SourceSample], toggleCurrent: Bool) {
        let row = table.selectedRow
        guard row >= 0 && row < samples.count else {
            stopPreview()
            setStatus("Select a WAV file to preview.", error: true)
            return
        }

        if toggleCurrent && player?.isPlaying == true && playingList == list && playingIndex == row {
            stopPreview()
            setStatus("Preview stopped.", error: false)
            return
        }

        startPreview(list: list, row: row, sample: samples[row])
    }

    private func startPreview(list: PlaybackList, row: Int, sample: SourceSample) {
        stopPreview(reload: false)
        do {
            player = try AVAudioPlayer(contentsOf: sample.url)
            playingList = list
            playingIndex = row
            player?.prepareToPlay()
            player?.play()
            reloadPlaybackTables()
            setStatus("Previewing \(sample.name). Press Space to stop.", error: false)
        } catch {
            stopPreview()
            setStatus("Could not preview WAV: \(error.localizedDescription)", error: true)
        }
    }

    private func playIcon(for list: PlaybackList, row: Int) -> String {
        player?.isPlaying == true && playingList == list && playingIndex == row ? "▶" : ""
    }

    private func reloadPlaybackTables() {
        let inputSelection = fileTable.selectedRow
        let outputSelection = outputTable.selectedRow
        let firstResponder = window.firstResponder
        isRefreshingPlaybackTables = true
        fileTable.reloadData()
        outputTable.reloadData()
        restoreSelection(inputSelection, in: fileTable, count: samples.count)
        restoreSelection(outputSelection, in: outputTable, count: outputSamples.count)
        isRefreshingPlaybackTables = false
        if firstResponder === fileTable || firstResponder === outputTable {
            window.makeFirstResponder(firstResponder)
        }
    }

    private func restoreSelection(_ row: Int, in table: NSTableView, count: Int) {
        guard row >= 0 && row < count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return attrs[.size] as? Int ?? 0
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func historyID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var `default`: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DateFormatter {
    static var history: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
