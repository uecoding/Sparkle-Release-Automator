import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - ViewModel
class ReleaseBuilderViewModel: ObservableObject {
    
    // MARK: - State
    @Published var statusMessage: String = "Checking Keychain..."
    @Published var generatedXML: String = ""
    @Published var isProcessing: Bool = false
    @Published var isAppLoaded: Bool = false
    @Published var isGenerated: Bool = false
    
    // Key Management
    @Published var isKeyInKeychain: Bool = false
    @Published var showPublicKeySheet: Bool = false
    @Published var currentPublicKey: String = ""
    
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
        checkKeychainStatus()
    }
    
    // MARK: - Key Management Logic
    
    func checkKeychainStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let keyToolUrl = Bundle.main.url(forResource: "generate_keys", withExtension: nil) else { return }
                
                // Running 'generate_keys -p' prints ONLY the raw key string if found.
                // If no key exists, the tool exits with a non-zero code, which runCommand catches.
                let output = try self.runCommand(executable: keyToolUrl, arguments: ["-p"])
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                
                DispatchQueue.main.async {
                    if !trimmed.isEmpty {
                        self.isKeyInKeychain = true
                        self.currentPublicKey = trimmed
                        self.statusMessage = "Ready. Key found in Keychain."
                    } else {
                        // This technically shouldn't happen if exit code was 0, but good to handle
                        self.isKeyInKeychain = false
                        self.statusMessage = "Keychain returned empty key data."
                    }
                }
            } catch {
                // If generates_keys fails (exit code != 0), it means no key was found in Keychain
                DispatchQueue.main.async {
                    self.isKeyInKeychain = false
                    self.statusMessage = "Ready (No Key Detected)."
                }
            }
        }
    }
    
    func showPublicKey() {
        if !currentPublicKey.isEmpty {
            showPublicKeySheet = true
        } else {
            checkKeychainStatus()
        }
    }
    
    // MARK: - Step 1: Analyze Dropped File
    func processDroppedFile(url: URL) {
        guard url.pathExtension == "app" else {
            statusMessage = "Error: Please drop a valid .app file."
            return
        }
        
        self.resetState()
        self.droppedAppUrl = url
        
        do {
            let info = try getAppInfo(appUrl: url)
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
        guard let url = droppedAppUrl else { return }
        
        if !isKeyInKeychain {
            statusMessage = "Error: No Key in Keychain. Run 'generate_keys' in Terminal first."
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
            // 1. Zip
            let zipUrl = try createZip(from: appUrl, name: self.appName, version: self.appShortVersion)
            
            // 2. Sign (Automatic Keychain Lookup)
            let signatureData = try signUpdate(zipUrl: zipUrl)
            
            DispatchQueue.main.async {
                self.zipLocation = zipUrl
                self.currentSignature = signatureData
                
                // 3. Generate XML (and auto-save)
                self.regenerateXML(forceUrl: nil)
                
                self.statusMessage = "Success! Zip created, signed, and XML saved."
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
        statusMessage = "XML updated with new URL and saved to disk."
    }
    
    private func regenerateXML(forceUrl: String?) {
        guard let sig = currentSignature else { return }
        
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
        
        // Auto-save immediately after generation/update
        saveAutoGeneratedXML()
    }
    
    private func saveAutoGeneratedXML() {
        guard let appUrl = droppedAppUrl else { return }
        
        // Save in the same folder as the .app
        let folder = appUrl.deletingLastPathComponent()
        let destination = folder.appendingPathComponent("appcast.xml")
        
        do {
            try generatedXML.write(to: destination, atomically: true, encoding: .utf8)
            print("Auto-saved XML to: \(destination.path)")
        } catch {
            print("Failed to auto-save XML: \(error.localizedDescription)")
            statusMessage = "Warning: Could not save appcast.xml to disk."
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
        let zipName = "\(name)-v\(version).zip"
        let destination = folder.appendingPathComponent(zipName)
        
        try? FileManager.default.removeItem(at: destination)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", appUrl.path, destination.path]
        
        _ = try runCommand(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: process.arguments!)
        
        return destination
    }
    
    struct SignatureResult {
        let signature: String
        let length: String
    }
    
    private func signUpdate(zipUrl: URL) throws -> SignatureResult {
        guard let signToolUrl = Bundle.main.url(forResource: "sign_update", withExtension: nil) else {
             throw NSError(domain: "App", code: 2, userInfo: [NSLocalizedDescriptionKey: "sign_update tool not found."])
        }
        
        // NO ARGUMENTS (besides the zip path) = Use Keychain
        let output = try runCommand(executable: signToolUrl, arguments: [zipUrl.path])
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
    
    // MARK: - Robust Command Runner
    private func runCommand(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        try process.run()
        
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        
        process.waitUntilExit()
        
        let outString = String(data: outData, encoding: .utf8) ?? ""
        let errString = String(data: errData, encoding: .utf8) ?? ""
        
        // Sparkle tools exit with non-zero if they fail (e.g. key not found)
        if process.terminationStatus != 0 {
            throw NSError(domain: "Shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Command failed: \(errString)"])
        }
        
        return outString + (outString.isEmpty ? errString : "")
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
        .sheet(isPresented: $vm.showPublicKeySheet) {
            PublicKeySheet(publicKey: vm.currentPublicKey)
        }
    }
    
    // MARK: - Subviews
    
    var sidebar: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Configuration")
                    .font(.headline)
                    .padding(.bottom, 5)
                
                // Key Status Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Private Key Status")
                        .font(.caption).bold()
                    
                    HStack {
                        Image(systemName: vm.isKeyInKeychain ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(vm.isKeyInKeychain ? .green : .orange)
                        Text(vm.isKeyInKeychain ? "Found in Keychain" : "Missing from Keychain")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                    
                    if vm.isKeyInKeychain {
                        Button(action: { vm.showPublicKey() }) {
                            Label("Show Public Key", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                    } else {
                        Text("No key found. Run `generate_keys` in Terminal to create one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    // Refresh Button
                    Button(action: { vm.checkKeychainStatus() }) {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .padding(.top, 5)
                }
                
                Spacer()
                
                // MARK: - About App Section
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 42, height: 42)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sparkle Release Automator")
                            .font(.system(size: 12, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.9))
                        
                        Text("Copyright © 2025 Umut Erhan")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.top, 2)
                        
                        
                        
                    }
                }
                .padding(.bottom, 5)
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
                VStack(spacing: 15) {
                    if let icon = vm.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text(vm.appName).font(.title2).bold()
                    Text("Version: \(vm.appShortVersion) (\(vm.appVersion))").font(.body).foregroundColor(.secondary)
                    
                    if vm.isKeyInKeychain {
                        Button(action: { vm.generateRelease() }) {
                            Label("Generate Zip and Sign", systemImage: "sparkles")
                                .font(.headline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 5)
                    } else {
                        Text("Missing Private Key in Keychain.")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            } else {
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
                        Text("Update URL").font(.headline).fontWeight(.semibold)
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
            
            // "Export XML" button removed as requested
            
            if let zipUrl = vm.zipLocation {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([zipUrl])
                }) {
                    HStack {
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.title3)
                        Text("Reveal Files").font(.title3).fontWeight(.semibold)
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
}

// MARK: - Public Key Sheet
struct PublicKeySheet: View {
    let publicKey: String
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 40))
                .foregroundColor(.blue)
            
            Text("Public Key String")
                .font(.title2)
                .bold()
            
            Text("This is the raw public key from your Keychain.")
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 5) {
                Text("In Info.plist, it should look like this:")
                    .font(.caption)
                    .bold()
                Text("<key>SUPublicEDKey</key>")
                    .font(.caption).fontDesign(.monospaced)
                Text("<string>\(publicKey.prefix(10))...</string>")
                    .font(.caption).fontDesign(.monospaced)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
            
            TextEditor(text: .constant(publicKey))
                .font(.system(.body, design: .monospaced))
                .frame(height: 80)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            
            HStack {
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                }
                
                Button("Done") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 500)
    }
}
