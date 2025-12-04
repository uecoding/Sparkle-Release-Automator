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
    
    // MARK: - Inputs/Outputs
    @Published var downloadUrl: String = ""
    @Published var statusMessage: String = "Ready. Drop your .app file here."
    @Published var generatedXML: String = ""
    @Published var isProcessing: Bool = false
    @Published var zipLocation: URL?
    
    // App Metadata
    @Published var appName: String = "--"
    @Published var appVersion: String = "--"
    @Published var appIcon: NSImage? = nil
    
    // Internal state
    private var currentSignature: SignatureResult?
    private var currentAppInfo: AppInfo?
    
    init() {
        self.sparkleToolsPath = UserDefaults.standard.string(forKey: "sparkleToolsPath") ?? ""
        self.privateKeyPath = UserDefaults.standard.string(forKey: "privateKeyPath") ?? ""
    }
    
    // MARK: - Actions
    
    func applyUrlToXML() {
        guard !downloadUrl.isEmpty else { return }
        regenerateXML(forceUrl: downloadUrl)
    }
    
    func processDroppedFile(url: URL) {
        guard url.pathExtension == "app" else {
            statusMessage = "Error: Please drop a valid .app file."
            return
        }
        
        guard !sparkleToolsPath.isEmpty, !privateKeyPath.isEmpty else {
            statusMessage = "Error: Please configure SparkleTools and Private Key paths first."
            return
        }
        
        isProcessing = true
        statusMessage = "Processing \(url.lastPathComponent)..."
        // Reset URL field when new file is dropped
        downloadUrl = ""
        
        do {
            let info = try getAppInfo(appUrl: url)
            
            // UI Updates
            DispatchQueue.main.async {
                self.currentAppInfo = info
                self.appName = info.name
                self.appVersion = "\(info.shortVersion) (\(info.version))"
                self.appIcon = NSWorkspace.shared.icon(forFile: url.path)
            }
            
            // Background Work
            DispatchQueue.global(qos: .userInitiated).async {
                self.runBackgroundTasks(appUrl: url, info: info)
            }
        } catch {
            statusMessage = "Error reading App Info: \(error.localizedDescription)"
            isProcessing = false
        }
    }
    
    private func runBackgroundTasks(appUrl: URL, info: AppInfo) {
        do {
            // 1. Zip
            let zipUrl = try createZip(from: appUrl)
            
            // 2. Sign
            let signatureData = try signUpdate(zipUrl: zipUrl)
            
            DispatchQueue.main.async {
                self.zipLocation = zipUrl
                self.currentSignature = signatureData
                
                // Generate initial XML with placeholder
                self.regenerateXML(forceUrl: nil)
                
                self.statusMessage = "Success! Zip created."
                self.isProcessing = false
            }
            
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.isProcessing = false
            }
        }
    }
    
    // MARK: - XML Logic
    
    private func regenerateXML(forceUrl: String?) {
        guard let info = currentAppInfo,
              let sig = currentSignature else { return }
        
        // Use provided URL, or default placeholder
        let finalURL = forceUrl ?? "INSERT_URL_HERE"
        
        self.generatedXML = generateXMLString(
            info: info,
            signatureData: sig,
            url: finalURL
        )
    }
    
    private func generateXMLString(info: AppInfo, signatureData: SignatureResult, url: String) -> String {
        let dateParams = DateFormatter()
        dateParams.dateFormat = "E, d MMM yyyy HH:mm:ss Z"
        dateParams.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateParams.string(from: Date())
        
        // Matching your exact requested structure
        return """
        <item>
            <title>\(info.shortVersion)</title>
            <pubDate>\(dateString)</pubDate>
            <sparkle:version>\(info.version)</sparkle:version>
            <sparkle:shortVersionString>\(info.shortVersion)</sparkle:shortVersionString>
            <enclosure 
                url="\(url)" 
                sparkle:edSignature="\(signatureData.signature)" 
                length="\(signatureData.length)" 
                type="application/octet-stream" />
        </item>
        """
    }

    // MARK: - Shell / File Operations
    
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
    
    private func createZip(from appUrl: URL) throws -> URL {
        let folder = appUrl.deletingLastPathComponent()
        let zipName = appUrl.deletingPathExtension().lastPathComponent + "-\(Date().timeIntervalSince1970).zip"
        let destination = folder.appendingPathComponent(zipName)
        
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
            // Left Sidebar: Configuration & Info
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
                
                Divider()
                
                Text("App Details")
                    .font(.headline)
                
                HStack(alignment: .top) {
                    if let icon = vm.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 48, height: 48)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(vm.appName)
                            .font(.system(size: 16, weight: .bold))
                        Text(vm.appVersion)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding()
            .frame(width: 260)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Right Side: Action & Output
            VStack(spacing: 20) {
                
                // 1. Drop Zone
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(vm.isProcessing ? Color.orange.opacity(0.1) : Color.blue.opacity(0.05))
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10]))
                        .foregroundColor(vm.isProcessing ? .orange : .blue.opacity(0.5))
                    
                    VStack(spacing: 15) {
                        if vm.isProcessing {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(vm.statusMessage)
                                .font(.headline)
                        } else {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                                .foregroundColor(.blue)
                            Text("Drop .app file here")
                                .font(.title2)
                                .bold()
                        }
                    }
                }
                .frame(height: 150)
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
                
                // 2. XML Preview
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Generated XML")
                            .font(.headline)
                        Spacer()
                        if !vm.generatedXML.isEmpty {
                            Button("Copy to Clipboard") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vm.generatedXML, forType: .string)
                            }
                            .font(.caption)
                        }
                    }
                    
                    TextEditor(text: .constant(vm.generatedXML))
                        .font(.system(.body, design: .monospaced))
                        .border(Color.gray.opacity(0.2))
                        .frame(minHeight: 250)
                }
                
                // 3. URL Input Section
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Download URL")
                            .font(.caption).bold()
                        TextField("Paste shortened link here...", text: $vm.downloadUrl)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    Button("Add URL") {
                        vm.applyUrlToXML()
                    }
                    .disabled(vm.downloadUrl.isEmpty || vm.generatedXML.isEmpty)
                }
                .padding(.top, 5)
                
                HStack {
                    Spacer()
                    if let zipUrl = vm.zipLocation {
                        Button("Reveal Zip in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([zipUrl])
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 850, minHeight: 650)
    }
    
    // Helpers
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
