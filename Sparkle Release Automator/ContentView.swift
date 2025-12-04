import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - ViewModel
class ReleaseBuilderViewModel: ObservableObject {
    
    // MARK: - Persistent Settings
    @Published var sparkleToolsPath: String {
        didSet { UserDefaults.standard.set(sparkleToolsPath, forKey: "sparkleToolsPath") }
    }
    
    @Published var privateKeyPath: String {
        didSet { UserDefaults.standard.set(privateKeyPath, forKey: "privateKeyPath") }
    }
    
    // MARK: - State
    @Published var statusMessage: String = "Ready. Drop your .app file here."
    @Published var generatedXML: String = ""
    @Published var isProcessing: Bool = false
    @Published var isAppLoaded: Bool = false
    @Published var isGenerated: Bool = false
    
    // Inputs
    @Published var downloadUrl: String = ""
    @Published var droppedAppUrl: URL?
    @Published var zipLocation: URL?
    
    // App Metadata
    @Published var appName: String = "--"
    @Published var appVersion: String = "--"
    @Published var appShortVersion: String = "--"
    @Published var appIcon: NSImage? = nil
    
    // Internal Data
    private var currentSignature: SignatureResult?
    
    init() {
        self.sparkleToolsPath = UserDefaults.standard.string(forKey: "sparkleToolsPath") ?? ""
        self.privateKeyPath = UserDefaults.standard.string(forKey: "privateKeyPath") ?? ""
    }
    
    // MARK: - Step 1: Analyze Dropped File
    func processDroppedFile(url: URL) {
        guard url.pathExtension == "app" else {
            statusMessage = "Error: Please drop a valid .app file."
            return
        }
        
        // Reset State
        self.resetState()
        self.droppedAppUrl = url
        
        do {
            let info = try getAppInfo(appUrl: url)
            
            // UI Updates
            DispatchQueue.main.async {
                self.appName = info.name
                self.appVersion = info.version
                self.appShortVersion = info.shortVersion
                self.appIcon = NSWorkspace.shared.icon(forFile: url.path)
                self.isAppLoaded = true
                self.statusMessage = "App loaded. Ready to generate."
            }
        } catch {
            statusMessage = "Error reading App Info: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Step 2: Generate (Zip & Sign)
    func generateRelease() {
        guard let url = droppedAppUrl,
              !sparkleToolsPath.isEmpty,
              !privateKeyPath.isEmpty else {
            statusMessage = "Error: Missing file or configuration."
            return
        }
        
        isProcessing = true
        statusMessage = "Zipping and Signing..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.runBackgroundTasks(appUrl: url)
        }
    }
    
    private func runBackgroundTasks(appUrl: URL) {
        do {
            // 1. Zip (Naming: AppName-vVersion.zip)
            let zipUrl = try createZip(from: appUrl, name: self.appName, version: self.appShortVersion)
            
            // 2. Sign
            let signatureData = try signUpdate(zipUrl: zipUrl)
            
            DispatchQueue.main.async {
                self.zipLocation = zipUrl
                self.currentSignature = signatureData
                
                // Generate initial XML with placeholder
                self.regenerateXML(forceUrl: nil)
                
                self.statusMessage = "Success! Zip created and signed."
                self.isProcessing = false
                self.isGenerated = true
            }
            
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }
    
    // MARK: - Step 3: XML & URL
    func applyUrlToXML() {
        guard !downloadUrl.isEmpty else { return }
        regenerateXML(forceUrl: downloadUrl)
    }
    
    private func regenerateXML(forceUrl: String?) {
        guard let sig = currentSignature else { return }
        
        // Use provided URL, or default placeholder
        let finalURL = forceUrl ?? "INSERT_URL_HERE"
        
        let dateParams = DateFormatter()
        dateParams.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        dateParams.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateParams.string(from: Date())
        
        self.generatedXML = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>\(appName) Updates</title>
                <item>
                    <title>\(appShortVersion)</title>
                    <pubDate>\(dateString)</pubDate>
                    <sparkle:version>\(appVersion)</sparkle:version>
                    <sparkle:shortVersionString>\(appShortVersion)</sparkle:shortVersionString>
                    <enclosure 
                        url="\(finalURL)" 
                        sparkle:edSignature="\(sig.signature)" 
                        length="\(sig.length)" 
                        type="application/octet-stream" />
                </item>
            </channel>
        </rss>
        """
    }
    
    func exportXML() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.xml]
        savePanel.nameFieldStringValue = "appcast.xml"
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? self.generatedXML.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    private func resetState() {
        isAppLoaded = false
        isGenerated = false
        isProcessing = false
        generatedXML = ""
        downloadUrl = ""
        zipLocation = nil
        currentSignature = nil
    }

    // MARK: - Logic Helpers
    
    struct AppInfo {
        let version: String
        let shortVersion: String
        let name: String
    }
    
    private func getAppInfo(appUrl: URL) throws -> AppInfo {
        let plistUrl = appUrl.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistUrl)
        
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "App", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read Info.plist"])
        }
        
        let version = plist["CFBundleVersion"] as? String ?? "1.0"
        let shortVersion = plist["CFBundleShortVersionString"] as? String ?? "1.0"
        let name = appUrl.deletingPathExtension().lastPathComponent
        
        return AppInfo(version: version, shortVersion: shortVersion, name: name)
    }
    
    private func createZip(from appUrl: URL, name: String, version: String) throws -> URL {
        let folder = appUrl.deletingLastPathComponent()
        // Format: AppName-v0.2.1.zip
        let zipName = "\(name)-v\(version).zip"
        let destination = folder.appendingPathComponent(zipName)
        
        // Remove existing if any
        try? FileManager.default.removeItem(at: destination)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", appUrl.path, destination.path]
        
        try runProcess(process)
        return destination
    }
    
    struct SignatureResult {
        let signature: String
        let length: String
    }
    
    private func signUpdate(zipUrl: URL) throws -> SignatureResult {
        let signTool = URL(fileURLWithPath: sparkleToolsPath).appendingPathComponent("sign_update")
        
        guard FileManager.default.fileExists(atPath: signTool.path) else {
            throw NSError(domain: "App", code: 2, userInfo: [NSLocalizedDescriptionKey: "sign_update tool not found."])
        }
        
        let process = Process()
        process.executableURL = signTool
        process.arguments = ["--ed-key-file", privateKeyPath, zipUrl.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try runProcess(process)
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "App", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read signature output."])
        }
        
        return parseSignatureOutput(output)
    }
    
    private func parseSignatureOutput(_ output: String) -> SignatureResult {
        var sig = ""
        var len = ""
        
        if let sigRange = output.range(of: "sparkle:edSignature=\"([^\"]+)\"", options: .regularExpression) {
            let match = String(output[sigRange])
            sig = match.replacingOccurrences(of: "sparkle:edSignature=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        
        if let lenRange = output.range(of: "length=\"([^\"]+)\"", options: .regularExpression) {
            let match = String(output[lenRange])
            len = match.replacingOccurrences(of: "length=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        
        return SignatureResult(signature: sig, length: len)
    }
    
    private func runProcess(_ process: Process) throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown shell error"
            throw NSError(domain: "Shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject var vm = ReleaseBuilderViewModel()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            sidebar
            
            Divider()
            
            // Right Content
            VStack(spacing: 20) {
                dropZoneArea
                
                if vm.isGenerated {
                    xmlPreviewSection
                    urlInputSection
                    actionButtons
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 700)
    }
    
    // MARK: - Subviews
    
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Configuration")
                .font(.headline)
                .padding(.bottom, 5)
            
            Group {
                Text("SparkleTools Folder").font(.caption).bold()
                HStack {
                    TextField("Path", text: $vm.sparkleToolsPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("...") { selectFolder { vm.sparkleToolsPath = $0 } }
                }
                
                Text("Private Key File (.pem)").font(.caption).bold()
                HStack {
                    TextField("Path", text: $vm.privateKeyPath)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button("...") { selectFile { vm.privateKeyPath = $0 } }
                }
            }
            Spacer()
            
            // App Info Small Summary (if loaded)
            if vm.isAppLoaded {
                Divider()
                Text("App Details")
                    .font(.headline)
                HStack(alignment: .top) {
                    if let icon = vm.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading) {
                        Text(vm.appName).font(.system(size: 16, weight: .bold))
                        Text("v\(vm.appShortVersion) (\(vm.appVersion))")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(width: 260)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    var dropZoneArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(vm.isProcessing ? Color.orange.opacity(0.1) : Color.blue.opacity(0.05))
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10]))
                .foregroundColor(vm.isProcessing ? .orange : .blue.opacity(0.5))
            
            if vm.isProcessing {
                VStack(spacing: 15) {
                    ProgressView().scaleEffect(1.2)
                    Text(vm.statusMessage).font(.headline)
                }
            } else if vm.isAppLoaded {
                // App Loaded State
                VStack(spacing: 15) {
                    if let icon = vm.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text(vm.appName).font(.title2).bold()
                    Text("Version: \(vm.appShortVersion) (\(vm.appVersion))").font(.body).foregroundColor(.secondary)
                    
                    Button(action: { vm.generateRelease() }) {
                        Label("Generate Release", systemImage: "sparkles")
                            .font(.headline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 5)
                }
            } else {
                // Empty State
                VStack(spacing: 15) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    Text("Drop .app file here")
                        .font(.title2)
                        .bold()
                }
            }
        }
        .frame(height: 200)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data = data, let path = String(data: data, encoding: .utf8), let url = URL(string: path) {
                    DispatchQueue.main.async {
                        vm.processDroppedFile(url: url)
                    }
                }
            }
            return true
        }
    }
    
    var xmlPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("XML Preview")
                .font(.headline)
                .padding(.horizontal, 4)
            
            TextEditor(text: .constant(vm.generatedXML))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minHeight: 200)
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LinearGradient(colors: [.accentColor.opacity(0.4), .pink], startPoint: .topTrailing, endPoint: .bottom).opacity(0.5), lineWidth: 1)
        )
    }
    
    var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Download URL")
                .font(.headline)
                .padding(.horizontal, 4)
            
            HStack {
                TextField("Paste direct download link for the zip here...", text: $vm.downloadUrl)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                
                Button(action: { vm.applyUrlToXML() }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.headline)
                        Text("Update XML").font(.headline).fontWeight(.semibold)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.5))
                .disabled(vm.downloadUrl.isEmpty)
            }
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LinearGradient(colors: [.accentColor.opacity(0.4), .cyan], startPoint: .topTrailing, endPoint: .bottom).opacity(0.5), lineWidth: 1)
        )
    }
    
    var actionButtons: some View {
        HStack(spacing: 15) {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.generatedXML, forType: .string)
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "doc.on.doc").font(.title3)
                    Text("Copy XML").font(.title3).fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
                .buttonStyle(.borderedProminent)
                .tint(.green.opacity(0.3))
                .controlSize(.large)
            
            Button(action: { vm.exportXML() }) {
                HStack {
                    Spacer()
                    Image(systemName: "square.and.arrow.up").font(.title3)
                    Text("Export XML").font(.title3).fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
                .buttonStyle(.borderedProminent)
                .tint(.orange.opacity(0.3))
                .controlSize(.large)
            
            if let zipUrl = vm.zipLocation {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([zipUrl])
                }) {
                    HStack {
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.title3)
                        Text("Reveal Zip").font(.title3).fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor.opacity(0.3))
                .controlSize(.large)
            }
        }
        .padding(.top, 5)
    }
    
    // MARK: - Helpers
    func selectFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
    
    func selectFile(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
