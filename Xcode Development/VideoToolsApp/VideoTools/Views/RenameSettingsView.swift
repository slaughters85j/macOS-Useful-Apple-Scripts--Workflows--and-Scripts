import SwiftUI

/// Right panel settings view for both Rename Videos and Rename Photos modes.
struct RenameSettingsView: View {
    let mode: ToolMode
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 20) {
            // MARK: - Naming Pattern Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Naming Pattern", systemImage: "textformat")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prefix")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Folder name", text: $state.renamePrefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: appState.renamePrefix) { _, _ in
                                appState.updateRenamePreview()
                            }
                    }

                    // Live preview
                    if let folder = appState.activeRenameFolder,
                       let first = folder.discoveredFiles.first {
                        HStack(spacing: 6) {
                            Text("Preview:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(first.proposedName)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - Numbering Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Numbering", systemImage: "number")
                        .font(.headline)

                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start at")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Stepper(
                                value: Binding(
                                    get: { appState.renameStartNumber },
                                    set: { appState.renameStartNumber = $0; appState.updateRenamePreview() }
                                ),
                                in: 0...999999
                            ) {
                                Text("\(appState.renameStartNumber)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 50, alignment: .trailing)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Digits")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Stepper(
                                value: Binding(
                                    get: { appState.renamePaddingWidth },
                                    set: { appState.renamePaddingWidth = $0; appState.updateRenamePreview() }
                                ),
                                in: 1...8
                            ) {
                                Text("\(appState.renamePaddingWidth)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 30, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - Sort Order Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sort Order", systemImage: "arrow.up.arrow.down")
                        .font(.headline)

                    Picker("Sort by", selection: Binding(
                        get: { appState.renameSortOrder },
                        set: { appState.renameSortOrder = $0; appState.updateRenamePreview() }
                    )) {
                        ForEach(RenameSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: Binding(
                        get: { appState.renameSortAscending },
                        set: { appState.renameSortAscending = $0; appState.updateRenamePreview() }
                    )) {
                        HStack {
                            Image(systemName: appState.renameSortAscending ? "arrow.up" : "arrow.down")
                            Text(appState.renameSortAscending ? "Ascending" : "Descending")
                        }
                        .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }

            // MARK: - Summary Section
            if let folder = appState.activeRenameFolder {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Summary", systemImage: "list.bullet")
                            .font(.headline)

                        summaryRow(label: "Total files", value: "\(folder.discoveredFiles.count)")

                        // File type breakdown
                        let extCounts = Dictionary(grouping: folder.discoveredFiles, by: \.fileExtension)
                            .mapValues(\.count)
                            .sorted { $0.value > $1.value }
                        let breakdown = extCounts.map { "\($0.value) .\($0.key)" }.joined(separator: ", ")
                        summaryRow(label: "Types", value: breakdown)

                        let collisions = folder.discoveredFiles.filter { $0.status == .collision }.count
                        if collisions > 0 {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("\(collisions) naming collision\(collisions == 1 ? "" : "s") detected")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
        }
    }
}

#Preview {
    RenameSettingsView(mode: .renameVideos)
        .environment(AppState())
        .frame(width: 380, height: 600)
        .padding()
}
