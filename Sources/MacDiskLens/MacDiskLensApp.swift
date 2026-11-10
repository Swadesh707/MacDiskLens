import AppKit
import SwiftUI

@main
struct MacDiskLensApp: App {
    var body: some Scene {
        WindowGroup("MacDiskLens") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class DiskViewModel: ObservableObject {
    @Published var categories: [CategoryUsage] = []
    @Published var entries: [DiskEntry] = []
    @Published var selectedCategory = "All"
    @Published var selectedIDs: Set<String> = []
    @Published var isScanning = false
    @Published var status = "Ready to scan"
    @Published var scannedItems = 0
    @Published var inaccessibleItems = 0
    @Published var elapsed: TimeInterval = 0
    @Published var totalBytes: Int64 = 0
    @Published var availableBytes: Int64 = 0
    @Published var showingDeleteConfirmation = false

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    var filteredEntries: [DiskEntry] {
        if selectedCategory == "All" { return entries }
        return entries.filter { $0.category == selectedCategory }
    }

    var selectedEntries: [DiskEntry] { entries.filter { selectedIDs.contains($0.id) } }

    func revealInFinder(_ entry: DiskEntry) {
        NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
    }

    func openFolderInFinder(_ entry: DiskEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let folder = entry.isDirectory ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open(folder)
    }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        status = "Scanning the disk…"
        selectedIDs.removeAll()
        scanTask = Task {
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            categories = result.categories
            entries = result.largest
            scannedItems = result.scannedItems
            inaccessibleItems = result.inaccessibleItems
            elapsed = result.elapsed
            totalBytes = result.totalBytes
            availableBytes = result.availableBytes
            isScanning = false
            status = result.inaccessibleItems > 0
                ? "Scan complete · some locations need Full Disk Access"
                : "Scan complete"
        }
    }

    func cancel() {
        scanTask?.cancel()
        isScanning = false
        status = "Scan cancelled"
    }

    func moveSelectedToTrash() {
        let selected = selectedEntries
        var failed = false
        for entry in selected {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil) }
            catch { failed = true }
        }
        selectedIDs.removeAll()
        status = failed ? "Some items could not be moved to Trash" : "Selected items moved to Trash"
        scan()
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

struct ContentView: View {
    @StateObject private var model = DiskViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedCategory) {
                Label("Everything", systemImage: "internaldrive")
                    .tag("All")
                Section("Storage categories") {
                    ForEach(model.categories) { category in
                        HStack {
                            Label(category.name, systemImage: icon(for: category.name))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(byteString(category.bytes))
                                Text("\(category.itemCount) items")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .tag(category.name)
                    }
                }
            }
            .navigationTitle("Storage overview")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Can’t see everything?")
                        .font(.caption.weight(.semibold))
                    Text("Full Disk Access lets MacDiskLens read protected folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") { model.openFullDiskAccess() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding()
            }
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if model.isScanning {
                    scanningView
                } else if model.entries.isEmpty {
                    emptyView
                } else {
                    dashboardView
                }
            }
        }
        .confirmationDialog("Move selected items to Trash?", isPresented: $model.showingDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) { model.moveSelectedToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items remain recoverable in the Trash until you empty it.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacDiskLens")
                    .font(.title2.bold())
                Text("A simple view of what is using your Mac’s storage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                Button("Stop scanning") { model.cancel() }
            } else {
                Button(model.entries.isEmpty ? "Scan my Mac" : "Scan again", systemImage: "arrow.clockwise") { model.scan() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            Button("Show in Finder", systemImage: "magnifyingglass") {
                if let entry = model.selectedEntries.first { model.revealInFinder(entry) }
            }
            .disabled(model.selectedEntries.count != 1 || model.isScanning)
            Button("Move selected to Trash", systemImage: "trash") { model.showingDeleteConfirmation = true }
                .disabled(model.selectedIDs.isEmpty || model.isScanning)
        }
        .padding()
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Reading file sizes across your Mac")
            Text("The first scan can take a few minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("See what is using your storage")
                .font(.title2.bold())
            Text("MacDiskLens finds the biggest files and folders on your Mac.\nNothing is deleted unless you choose it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Scan my Mac", systemImage: "magnifyingglass") { model.scan() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var dashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                storageHero
                categoryOverview
                fileList
            }
            .padding(20)
        }
    }

    private var storageHero: some View {
        let total = max(model.totalBytes, 1)
        let used = max(model.totalBytes - model.availableBytes, 0)
        let usedRatio = min(Double(used) / Double(total), 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Mac at a glance")
                        .font(.title3.bold())
                    Text("See where your storage is going before you delete anything.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
            }
            ProgressView(value: usedRatio)
                .tint(usedRatio > 0.9 ? .orange : .accentColor)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .padding(.vertical, 4)
            HStack {
                Label("Used \(byteString(used))", systemImage: "circle.fill")
                    .foregroundStyle(usedRatio > 0.9 ? .orange : .primary)
                Spacer()
                Label("Free \(byteString(model.availableBytes))", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            if usedRatio > 0.9 {
                Label("Your Mac is nearly full. Start with the largest items below.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }

    private var categoryOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Where space is going")
                    .font(.title3.bold())
                Spacer()
                Text("Click a category to filter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let largest = max(model.categories.map(\.bytes).max() ?? 1, 1)
            ForEach(model.categories.prefix(6)) { category in
                Button {
                    model.selectedCategory = category.name
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(category.name, systemImage: icon(for: category.name))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(byteString(category.bytes))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: geometry.size.width * CGFloat(category.bytes) / CGFloat(largest))
                                }
                        }
                        .frame(height: 8)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedCategory == "All" ? "Largest files and folders" : model.selectedCategory)
                        .font(.title3.bold())
                    Text("Select an item to reveal it in Finder or move it to Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Top 500")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Table(model.filteredEntries, selection: $model.selectedIDs) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .help(entry.path)
                        .contextMenu {
                            Button("Show in Finder", systemImage: "magnifyingglass") { model.revealInFinder(entry) }
                            Button("Open containing folder", systemImage: "folder") { model.openFolderInFinder(entry) }
                        }
                }
                TableColumn("Category") { entry in Text(entry.category) }
                TableColumn("Size") { entry in Text(byteString(entry.displayBytes)).monospacedDigit() }
                TableColumn("Location") { entry in Text(entry.path).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("Actions") { entry in
                    HStack(spacing: 8) {
                        Button("Show in Finder", systemImage: "magnifyingglass") { model.revealInFinder(entry) }
                            .help("Reveal this item in Finder")
                        Button("Open folder", systemImage: "folder") { model.openFolderInFinder(entry) }
                            .help("Open containing folder")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(minHeight: 300)
        }
    }

    private func icon(for category: String) -> String {
        switch category {
        case "Applications": return "app.dashed"
        case "Documents": return "doc.text"
        case "Downloads": return "arrow.down.circle"
        case "Developer files": return "hammer"
        case "Virtual machines": return "desktopcomputer"
        case "Caches": return "sparkles"
        case "Logs": return "list.bullet.rectangle"
        default: return "folder"
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
