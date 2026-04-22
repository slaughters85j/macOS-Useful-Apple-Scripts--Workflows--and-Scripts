import SwiftUI

// MARK: - Text Overlay Editor View

/// A sheet for editing text overlay content and styling.
/// Provides controls for text, font, color, shadow, and gradient settings.
struct TextOverlayEditorView: View {
    @Binding var textOverlay: TextOverlay?
    @Binding var isPresented: Bool

    /// Snapshot of the overlay when the editor opens, for cancel/restore.
    @State private var originalOverlay: TextOverlay?

    var body: some View {
        if var overlay = textOverlay {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Header
                HStack {
                    Label("Text Overlay", systemImage: "textformat")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        textOverlay = originalOverlay
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)
                    Button("Done") {
                        isPresented = false
                    }
                    .keyboardShortcut(.return)
                }

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // MARK: - Text Input
                        textInputSection(overlay: &overlay)

                        Divider()

                        // MARK: - Font Settings
                        fontSection(overlay: &overlay)

                        Divider()

                        // MARK: - Color
                        colorSection(overlay: &overlay)

                        Divider()

                        // MARK: - Shadow
                        shadowSection(overlay: &overlay)

                        Divider()

                        // MARK: - Gradient
                        gradientSection(overlay: &overlay)
                    }
                }
            }
            .padding()
            .frame(width: 380, height: 520)
            .onAppear { originalOverlay = textOverlay }
        }
    }

    // MARK: - Text Input Section

    private func textInputSection(overlay: inout TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Text")
            #if os(iOS)
            TextField("Enter text", text: bindingFor(\.text))
                .textFieldStyle(.roundedBorder)
            #else
            TextField("Enter text", text: bindingFor(\.text))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            #endif
        }
    }

    // MARK: - Font Section

    private func fontSection(overlay: inout TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Font")

            HStack {
                Text("Family")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Font", selection: bindingFor(\.fontName)) {
                    ForEach(CuratedFont.allCases) { font in
                        Text(font.displayName).tag(font.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            HStack {
                Text("Size")
                    .foregroundStyle(.secondary)
                Spacer()
                Slider(
                    value: Binding(
                        get: { Double(textOverlay?.fontSize ?? 48) },
                        set: { newValue in
                            textOverlay?.fontSize = Int(newValue)
                        }
                    ),
                    in: 12...120,
                    step: 2
                )
                .frame(width: 140)
                Text("\(textOverlay?.fontSize ?? 48)")
                    .monospacedDigit()
                    .frame(width: 35, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Toggle(isOn: bindingFor(\.isBold)) {
                    Text("B").bold()
                }
                .toggleStyle(.button)

                Toggle(isOn: bindingFor(\.isItalic)) {
                    Text("I").italic()
                }
                .toggleStyle(.button)
            }
        }
    }

    // MARK: - Color Section

    private func colorSection(overlay: inout TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Color")

            HStack {
                Text("Text Color")
                    .foregroundStyle(.secondary)
                Spacer()
                ColorPicker(
                    "",
                    selection: colorBinding(
                        get: { textOverlay?.textColor ?? .white },
                        set: { textOverlay?.textColor = $0 }
                    )
                )
                .labelsHidden()
            }
        }
    }

    // MARK: - Shadow Section

    private func shadowSection(overlay: inout TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bindingFor(\.hasShadow)) {
                sectionLabel("Shadow")
            }
            .toggleStyle(.switch)

            if textOverlay?.hasShadow == true {
                HStack {
                    Text("Shadow Color")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: colorBinding(
                            get: { textOverlay?.shadowColor ?? .black },
                            set: { textOverlay?.shadowColor = $0 }
                        )
                    )
                    .labelsHidden()
                }

                HStack {
                    Text("Offset X")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        "\(textOverlay?.shadowOffsetX ?? 2)",
                        value: Binding(
                            get: { textOverlay?.shadowOffsetX ?? 2 },
                            set: { textOverlay?.shadowOffsetX = $0 }
                        ),
                        in: -10...10
                    )
                    .frame(width: 120)
                }

                HStack {
                    Text("Offset Y")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        "\(textOverlay?.shadowOffsetY ?? 2)",
                        value: Binding(
                            get: { textOverlay?.shadowOffsetY ?? 2 },
                            set: { textOverlay?.shadowOffsetY = $0 }
                        ),
                        in: -10...10
                    )
                    .frame(width: 120)
                }
            }
        }
    }

    // MARK: - Gradient Section

    private func gradientSection(overlay: inout TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bindingFor(\.gradientEnabled)) {
                sectionLabel("Gradient")
            }
            .toggleStyle(.switch)

            if textOverlay?.gradientEnabled == true {
                Text("Overrides solid text color. Requires Pillow in Python.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack {
                    Text("Start Color")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: colorBinding(
                            get: { textOverlay?.gradientStartColor ?? .white },
                            set: { textOverlay?.gradientStartColor = $0 }
                        )
                    )
                    .labelsHidden()
                }

                HStack {
                    Text("End Color")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: colorBinding(
                            get: { textOverlay?.gradientEndColor ?? CodableColor(red: 0.3, green: 0.6, blue: 1.0) },
                            set: { textOverlay?.gradientEndColor = $0 }
                        )
                    )
                    .labelsHidden()
                }

                HStack {
                    Text("Angle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { textOverlay?.gradientAngle ?? 0 },
                            set: { textOverlay?.gradientAngle = $0 }
                        ),
                        in: 0...360,
                        step: 15
                    )
                    .frame(width: 140)
                    Text("\(Int(textOverlay?.gradientAngle ?? 0))°")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    /// Creates a binding to a writable key path on the optional TextOverlay
    private func bindingFor<T>(_ keyPath: WritableKeyPath<TextOverlay, T>) -> Binding<T> where T: Equatable {
        Binding(
            get: { textOverlay![keyPath: keyPath] },
            set: { textOverlay?[keyPath: keyPath] = $0 }
        )
    }

    /// Creates a Color binding that bridges CodableColor ↔ SwiftUI Color
    private func colorBinding(
        get: @escaping () -> CodableColor,
        set: @escaping (CodableColor) -> Void
    ) -> Binding<Color> {
        Binding<Color>(
            get: { get().swiftUIColor },
            set: { newColor in
                let nsColor = NSColor(newColor)
                set(CodableColor(from: nsColor))
            }
        )
    }
}
