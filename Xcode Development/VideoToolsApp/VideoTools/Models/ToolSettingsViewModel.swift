import Foundation
import SwiftData

@Observable
@MainActor
final class ToolSettingsViewModel {
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var appState: AppState?
    private var settings: AppSettings?
    private var revision = 0

    func configure(modelContext: ModelContext, appState: AppState) {
        guard self.modelContext == nil else { return }

        self.modelContext = modelContext
        self.appState = appState

        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.settingsID == "tool-settings" }
        )

        do {
            if let existingSettings = try modelContext.fetch(descriptor).first {
                settings = existingSettings
            } else {
                let newSettings = AppSettings()
                modelContext.insert(newSettings)
                settings = newSettings
                save()
            }
            applySettingsToAppState()
        } catch {
            print("ToolSettingsViewModel: Failed to load settings: \(error)")
        }
    }

    // MARK: - Splitter Settings

    var splitMethod: SplitMethod {
        get { readEnum(settings?.splitMethod, defaultValue: appState?.splitMethod ?? .duration) }
        set { update({ $0.splitMethod = newValue.rawValue }, apply: { $0.splitMethod = newValue }) }
    }

    var splitValue: Double {
        get { read(settings?.splitValue, defaultValue: appState?.splitValue ?? 60) }
        set { update({ $0.splitValue = newValue }, apply: { $0.splitValue = newValue }) }
    }

    var splitDurationUnit: DurationUnit {
        get { readEnum(settings?.splitDurationUnit, defaultValue: appState?.splitDurationUnit ?? .seconds) }
        set { update({ $0.splitDurationUnit = newValue.rawValue }, apply: { $0.splitDurationUnit = newValue }) }
    }

    var fpsMode: FPSMode {
        get { readEnum(settings?.fpsMode, defaultValue: appState?.fpsMode ?? .single) }
        set { update({ $0.fpsMode = newValue.rawValue }, apply: { $0.fpsMode = newValue }) }
    }

    var fpsValue: Double {
        get { read(settings?.fpsValue, defaultValue: appState?.fpsValue ?? 30) }
        set { update({ $0.fpsValue = newValue }, apply: { $0.fpsValue = newValue }) }
    }

    var outputCodec: OutputCodec {
        get { readEnum(settings?.outputCodec, defaultValue: appState?.outputCodec ?? .copy) }
        set { update({ $0.outputCodec = newValue.rawValue }, apply: { $0.outputCodec = newValue }) }
    }

    var qualityMode: QualityMode {
        get { readEnum(settings?.qualityMode, defaultValue: appState?.qualityMode ?? .quality) }
        set { update({ $0.qualityMode = newValue.rawValue }, apply: { $0.qualityMode = newValue }) }
    }

    var qualityValue: Double {
        get { read(settings?.qualityValue, defaultValue: appState?.qualityValue ?? 65) }
        set { update({ $0.qualityValue = newValue }, apply: { $0.qualityValue = newValue }) }
    }

    var outputFolderMode: OutputFolderMode {
        get { readEnum(settings?.outputFolderMode, defaultValue: appState?.outputFolderMode ?? .perFile) }
        set { update({ $0.outputFolderMode = newValue.rawValue }, apply: { $0.outputFolderMode = newValue }) }
    }

    // MARK: - Separator Settings

    var sampleRateMode: SampleRateMode {
        get { readEnum(settings?.sampleRateMode, defaultValue: appState?.sampleRateMode ?? .single) }
        set { update({ $0.sampleRateMode = newValue.rawValue }, apply: { $0.sampleRateMode = newValue }) }
    }

    var sampleRate: SampleRate {
        get { readSampleRate(settings?.sampleRate, defaultValue: appState?.sampleRate ?? .hz48000) }
        set { update({ $0.sampleRate = newValue.rawValue }, apply: { $0.sampleRate = newValue }) }
    }

    var audioChannelMode: AudioChannelMode {
        get { readAudioChannelMode(settings?.audioChannelMode, defaultValue: appState?.audioChannelMode ?? .stereo) }
        set { update({ $0.audioChannelMode = newValue.rawValue }, apply: { $0.audioChannelMode = newValue }) }
    }

    // MARK: - Merge Settings

    var mergeOutputFilename: String {
        get { read(settings?.mergeOutputFilename, defaultValue: appState?.mergeOutputFilename ?? "merged_output") }
        set { update({ $0.mergeOutputFilename = newValue }, apply: { $0.mergeOutputFilename = newValue }) }
    }

    var mergeAspectMode: MergeAspectMode {
        get { readEnum(settings?.mergeAspectMode, defaultValue: appState?.mergeAspectMode ?? .letterbox) }
        set { update({ $0.mergeAspectMode = newValue.rawValue }, apply: { $0.mergeAspectMode = newValue }) }
    }

    var mergeOutputCodec: OutputCodec {
        get { readEnum(settings?.mergeOutputCodec, defaultValue: appState?.mergeOutputCodec ?? .h264) }
        set { update({ $0.mergeOutputCodec = newValue.rawValue }, apply: { $0.mergeOutputCodec = newValue }) }
    }

    var mergeQualityMode: QualityMode {
        get { readEnum(settings?.mergeQualityMode, defaultValue: appState?.mergeQualityMode ?? .quality) }
        set { update({ $0.mergeQualityMode = newValue.rawValue }, apply: { $0.mergeQualityMode = newValue }) }
    }

    var mergeQualityValue: Double {
        get { read(settings?.mergeQualityValue, defaultValue: appState?.mergeQualityValue ?? 65) }
        set { update({ $0.mergeQualityValue = newValue }, apply: { $0.mergeQualityValue = newValue }) }
    }

    var mergeFpsValue: Double {
        get { read(settings?.mergeFpsValue, defaultValue: appState?.mergeFpsValue ?? 30) }
        set { update({ $0.mergeFpsValue = newValue }, apply: { $0.mergeFpsValue = newValue }) }
    }

    // MARK: - GIF Settings

    var gifResolutionMode: GifResolutionMode {
        get { readEnum(settings?.gifResolutionMode, defaultValue: appState?.gifResolutionMode ?? .scale) }
        set { update({ $0.gifResolutionMode = newValue.rawValue }, apply: { $0.gifResolutionMode = newValue }) }
    }

    var gifScalePercent: Double {
        get { read(settings?.gifScalePercent, defaultValue: appState?.gifScalePercent ?? 50) }
        set { update({ $0.gifScalePercent = newValue }, apply: { $0.gifScalePercent = newValue }) }
    }

    var gifFixedWidth: Int {
        get { read(settings?.gifFixedWidth, defaultValue: appState?.gifFixedWidth ?? 480) }
        set { update({ $0.gifFixedWidth = newValue }, apply: { $0.gifFixedWidth = newValue }) }
    }

    var gifCustomWidth: Int {
        get { read(settings?.gifCustomWidth, defaultValue: appState?.gifCustomWidth ?? 640) }
        set { update({ $0.gifCustomWidth = newValue }, apply: { $0.gifCustomWidth = newValue }) }
    }

    var gifCustomHeight: Int {
        get { read(settings?.gifCustomHeight, defaultValue: appState?.gifCustomHeight ?? 480) }
        set { update({ $0.gifCustomHeight = newValue }, apply: { $0.gifCustomHeight = newValue }) }
    }

    var gifFrameRate: Double {
        get { read(settings?.gifFrameRate, defaultValue: appState?.gifFrameRate ?? 15) }
        set { update({ $0.gifFrameRate = newValue }, apply: { $0.gifFrameRate = newValue }) }
    }

    var gifSpeedMultiplier: Double {
        get { read(settings?.gifSpeedMultiplier, defaultValue: appState?.gifSpeedMultiplier ?? 1.0) }
        set { update({ $0.gifSpeedMultiplier = newValue }, apply: { $0.gifSpeedMultiplier = newValue }) }
    }

    var gifLoopMode: GifLoopMode {
        get { readEnum(settings?.gifLoopMode, defaultValue: appState?.gifLoopMode ?? .infinite) }
        set { update({ $0.gifLoopMode = newValue.rawValue }, apply: { $0.gifLoopMode = newValue }) }
    }

    var gifLoopCount: Int {
        get { read(settings?.gifLoopCount, defaultValue: appState?.gifLoopCount ?? 3) }
        set { update({ $0.gifLoopCount = newValue }, apply: { $0.gifLoopCount = newValue }) }
    }

    var gifOutputFormat: GifOutputFormat {
        get { readEnum(settings?.gifOutputFormat, defaultValue: appState?.gifOutputFormat ?? .gif) }
        set { update({ $0.gifOutputFormat = newValue.rawValue }, apply: { $0.gifOutputFormat = newValue }) }
    }

    var gifTextFontName: String {
        get { readValidFontName(settings?.gifTextFontName, defaultValue: appState?.gifTextFontName ?? CuratedFont.helvetica.rawValue) }
        set {
            let fontName = readValidFontName(newValue, defaultValue: CuratedFont.helvetica.rawValue)
            update({ $0.gifTextFontName = fontName }, apply: { $0.gifTextFontName = fontName })
        }
    }

    // MARK: - Shared Settings

    var parallelJobs: Int {
        get { read(settings?.parallelJobs, defaultValue: appState?.parallelJobs ?? 4) }
        set { update({ $0.parallelJobs = newValue }, apply: { $0.parallelJobs = newValue }) }
    }

    // MARK: - Defaults

    func restoreSplitDefaults() {
        updateSettings { settings in
            let defaults = AppSettings()
            settings.splitMethod = defaults.splitMethod
            settings.splitValue = defaults.splitValue
            settings.splitDurationUnit = defaults.splitDurationUnit
            settings.fpsMode = defaults.fpsMode
            settings.fpsValue = defaults.fpsValue
            settings.outputCodec = defaults.outputCodec
            settings.qualityMode = defaults.qualityMode
            settings.qualityValue = defaults.qualityValue
            settings.outputFolderMode = defaults.outputFolderMode
            settings.parallelJobs = defaults.parallelJobs
        }
        applySplitSettingsToAppState()
    }

    func restoreSeparateDefaults() {
        updateSettings { settings in
            let defaults = AppSettings()
            settings.sampleRateMode = defaults.sampleRateMode
            settings.sampleRate = defaults.sampleRate
            settings.audioChannelMode = defaults.audioChannelMode
            settings.parallelJobs = defaults.parallelJobs
        }
        applySeparateSettingsToAppState()
    }

    func restoreMergeDefaults() {
        updateSettings { settings in
            let defaults = AppSettings()
            settings.mergeOutputFilename = defaults.mergeOutputFilename
            settings.mergeAspectMode = defaults.mergeAspectMode
            settings.mergeOutputCodec = defaults.mergeOutputCodec
            settings.mergeQualityMode = defaults.mergeQualityMode
            settings.mergeQualityValue = defaults.mergeQualityValue
            settings.mergeFpsValue = defaults.mergeFpsValue
        }
        applyMergeSettingsToAppState()
    }

    func restoreGifDefaults() {
        updateSettings { settings in
            let defaults = AppSettings()
            settings.gifResolutionMode = defaults.gifResolutionMode
            settings.gifScalePercent = defaults.gifScalePercent
            settings.gifFixedWidth = defaults.gifFixedWidth
            settings.gifCustomWidth = defaults.gifCustomWidth
            settings.gifCustomHeight = defaults.gifCustomHeight
            settings.gifFrameRate = defaults.gifFrameRate
            settings.gifSpeedMultiplier = defaults.gifSpeedMultiplier
            settings.gifLoopMode = defaults.gifLoopMode
            settings.gifLoopCount = defaults.gifLoopCount
            settings.gifOutputFormat = defaults.gifOutputFormat
            settings.gifTextFontName = defaults.gifTextFontName
        }
        applyGifSettingsToAppState()
    }

    // MARK: - Private Helpers

    private func applySettingsToAppState() {
        applySplitSettingsToAppState()
        applySeparateSettingsToAppState()
        applyMergeSettingsToAppState()
        applyGifSettingsToAppState()
        appState?.parallelJobs = parallelJobs
    }

    private func applySplitSettingsToAppState() {
        appState?.splitMethod = splitMethod
        appState?.splitValue = splitValue
        appState?.splitDurationUnit = splitDurationUnit
        appState?.fpsMode = fpsMode
        appState?.fpsValue = fpsValue
        appState?.outputCodec = outputCodec
        appState?.qualityMode = qualityMode
        appState?.qualityValue = qualityValue
        appState?.outputFolderMode = outputFolderMode
        appState?.parallelJobs = parallelJobs
    }

    private func applySeparateSettingsToAppState() {
        appState?.sampleRateMode = sampleRateMode
        appState?.sampleRate = sampleRate
        appState?.audioChannelMode = audioChannelMode
        appState?.parallelJobs = parallelJobs
    }

    private func applyMergeSettingsToAppState() {
        appState?.mergeOutputFilename = mergeOutputFilename
        appState?.mergeAspectMode = mergeAspectMode
        appState?.mergeOutputCodec = mergeOutputCodec
        appState?.mergeQualityMode = mergeQualityMode
        appState?.mergeQualityValue = mergeQualityValue
        appState?.mergeFpsValue = mergeFpsValue
        appState?.mergeOutputLocation = .firstFile
        appState?.mergeCustomOutputDir = nil
    }

    private func applyGifSettingsToAppState() {
        appState?.gifResolutionMode = gifResolutionMode
        appState?.gifScalePercent = gifScalePercent
        appState?.gifFixedWidth = gifFixedWidth
        appState?.gifCustomWidth = gifCustomWidth
        appState?.gifCustomHeight = gifCustomHeight
        appState?.gifFrameRate = gifFrameRate
        appState?.gifSpeedMultiplier = gifSpeedMultiplier
        appState?.gifLoopMode = gifLoopMode
        appState?.gifLoopCount = gifLoopCount
        appState?.gifOutputFormat = gifOutputFormat
        appState?.gifTextFontName = gifTextFontName
    }

    private func update(_ updateSettings: (AppSettings) -> Void, apply: (AppState) -> Void) {
        if let settings {
            updateSettings(settings)
            revision += 1
            save()
        }

        if let appState {
            apply(appState)
        }
    }

    private func updateSettings(_ update: (AppSettings) -> Void) {
        guard let settings else { return }
        update(settings)
        revision += 1
        save()
    }

    private func save() {
        do {
            try modelContext?.save()
        } catch {
            print("ToolSettingsViewModel: Failed to save settings: \(error)")
        }
    }

    private func read<T>(_ value: T?, defaultValue: T) -> T {
        _ = revision
        return value ?? defaultValue
    }

    private func readEnum<T: RawRepresentable>(_ value: String?, defaultValue: T) -> T where T.RawValue == String {
        _ = revision
        guard let value else { return defaultValue }
        return T(rawValue: value) ?? defaultValue
    }

    private func readSampleRate(_ value: Int?, defaultValue: SampleRate) -> SampleRate {
        _ = revision
        guard let value else { return defaultValue }
        return SampleRate(rawValue: value) ?? defaultValue
    }

    private func readAudioChannelMode(_ value: Int?, defaultValue: AudioChannelMode) -> AudioChannelMode {
        _ = revision
        guard let value else { return defaultValue }
        return AudioChannelMode(rawValue: value) ?? defaultValue
    }

    private func readValidFontName(_ value: String?, defaultValue: String) -> String {
        _ = revision
        guard let value, CuratedFont(rawValue: value) != nil else { return defaultValue }
        return value
    }
}
