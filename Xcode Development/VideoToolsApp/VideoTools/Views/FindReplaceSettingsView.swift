//
//  FindReplaceSettingsView.swift
//  VideoTools
//
//  Created by John Slaughter on 04/21/26.
//
//  Description:
//  Right panel settings view for Find & Replace rename mode. Provides find/replace
//  text fields, case sensitivity toggle, auto-detect prefix, and a summary of
//  pending changes.

import SwiftUI

// MARK: - Find & Replace Settings View

/// Right panel settings for Find & Replace rename mode.
struct FindReplaceSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(alignment: .leading, spacing: 20) {
            // MARK: - Find & Replace Section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Find & Replace", systemImage: "magnifyingglass")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Text to find in filenames", text: $state.findText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: appState.findText) { _, _ in
                                appState.updateFindReplacePreview()
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replace with")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("Leave empty to remove", text: $state.replaceText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: appState.replaceText) { _, _ in
                                appState.updateFindReplacePreview()
                            }
                    }

                    HStack {
                        Toggle(isOn: Binding(
                            get: { appState.findReplaceCaseSensitive },
                            set: {
                                appState.findReplaceCaseSensitive = $0
                                appState.updateFindReplacePreview()
                            }
                        )) {
                            Text("Case sensitive")
                                .font(.subheadline)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Spacer()

                        Button {
                            appState.autoDetectCommonPrefix()
                        } label: {
                            Label("Auto-detect", systemImage: "wand.and.stars")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.findReplaceFiles.count < 2)
                        .help("Detect common prefix across all filenames")
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - Live Preview Section
            if !appState.findReplaceFiles.isEmpty && !appState.findText.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Preview", systemImage: "eye")
                            .font(.headline)

                        if let firstMatch = appState.findReplaceFiles.first(where: {
                            $0.proposedName != $0.originalName
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(firstMatch.originalName)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)

                                    Text(firstMatch.proposedName)
                                        .font(.system(.caption, design: .monospaced, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("No filenames match \"\(appState.findText)\"")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // MARK: - Summary Section
            if !appState.findReplaceFiles.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Summary", systemImage: "list.bullet")
                            .font(.headline)

                        summaryRow(label: "Total files", value: "\(appState.findReplaceFiles.count)")

                        let dirCount = appState.findReplaceDirectoryCount
                        summaryRow(label: "Directories", value: "\(dirCount)")

                        let matchCount = appState.findReplaceMatchCount
                        summaryRow(label: "Will rename", value: "\(matchCount)")

                        let skipCount = appState.findReplaceFiles.count - matchCount
                        if skipCount > 0 {
                            summaryRow(label: "No change", value: "\(skipCount)")
                        }

                        // File type breakdown
                        let extCounts = Dictionary(grouping: appState.findReplaceFiles, by: \.fileExtension)
                            .mapValues(\.count)
                            .sorted { $0.value > $1.value }
                        let breakdown = extCounts.map { "\($0.value) .\($0.key)" }.joined(separator: ", ")
                        summaryRow(label: "Types", value: breakdown)

                        let collisions = appState.findReplaceFiles.filter { $0.status == .collision }.count
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

    // MARK: - Helpers

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

// MARK: - Preview

#Preview {
    FindReplaceSettingsView()
        .environment(AppState())
        .frame(width: 380, height: 600)
        .padding()
}
