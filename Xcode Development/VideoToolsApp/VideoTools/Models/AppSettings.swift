import Foundation
import SwiftData

@Model
final class AppSettings {
    var settingsID: String = "tool-settings"

    // Splitter settings
    var splitMethod: String = SplitMethod.duration.rawValue
    var splitValue: Double = 60
    var splitDurationUnit: String = DurationUnit.seconds.rawValue
    var fpsMode: String = FPSMode.single.rawValue
    var fpsValue: Double = 30
    var outputCodec: String = OutputCodec.copy.rawValue
    var qualityMode: String = QualityMode.quality.rawValue
    var qualityValue: Double = 65
    var outputFolderMode: String = OutputFolderMode.perFile.rawValue

    // Separator settings
    var sampleRateMode: String = SampleRateMode.single.rawValue
    var sampleRate: Int = SampleRate.hz48000.rawValue
    var audioChannelMode: Int = AudioChannelMode.stereo.rawValue

    // Merge settings
    var mergeOutputFilename: String = "merged_output"
    var mergeAspectMode: String = MergeAspectMode.letterbox.rawValue
    var mergeOutputCodec: String = OutputCodec.h264.rawValue
    var mergeQualityMode: String = QualityMode.quality.rawValue
    var mergeQualityValue: Double = 65
    var mergeFpsValue: Double = 30

    // GIF settings
    var gifResolutionMode: String = GifResolutionMode.scale.rawValue
    var gifScalePercent: Double = 50
    var gifFixedWidth: Int = 480
    var gifCustomWidth: Int = 640
    var gifCustomHeight: Int = 480
    var gifFrameRate: Double = 15
    var gifSpeedMultiplier: Double = 1.0
    var gifLoopMode: String = GifLoopMode.infinite.rawValue
    var gifLoopCount: Int = 3
    var gifOutputFormat: String = GifOutputFormat.gif.rawValue
    var gifTextFontName: String = CuratedFont.helvetica.rawValue

    // Shared settings
    var parallelJobs: Int = 4

    init(
        settingsID: String = "tool-settings",
        splitMethod: SplitMethod = .duration,
        splitValue: Double = 60,
        splitDurationUnit: DurationUnit = .seconds,
        fpsMode: FPSMode = .single,
        fpsValue: Double = 30,
        outputCodec: OutputCodec = .copy,
        qualityMode: QualityMode = .quality,
        qualityValue: Double = 65,
        outputFolderMode: OutputFolderMode = .perFile,
        sampleRateMode: SampleRateMode = .single,
        sampleRate: SampleRate = .hz48000,
        audioChannelMode: AudioChannelMode = .stereo,
        mergeOutputFilename: String = "merged_output",
        mergeAspectMode: MergeAspectMode = .letterbox,
        mergeOutputCodec: OutputCodec = .h264,
        mergeQualityMode: QualityMode = .quality,
        mergeQualityValue: Double = 65,
        mergeFpsValue: Double = 30,
        gifResolutionMode: GifResolutionMode = .scale,
        gifScalePercent: Double = 50,
        gifFixedWidth: Int = 480,
        gifCustomWidth: Int = 640,
        gifCustomHeight: Int = 480,
        gifFrameRate: Double = 15,
        gifSpeedMultiplier: Double = 1.0,
        gifLoopMode: GifLoopMode = .infinite,
        gifLoopCount: Int = 3,
        gifOutputFormat: GifOutputFormat = .gif,
        gifTextFontName: String = CuratedFont.helvetica.rawValue,
        parallelJobs: Int = 4
    ) {
        self.settingsID = settingsID
        self.splitMethod = splitMethod.rawValue
        self.splitValue = splitValue
        self.splitDurationUnit = splitDurationUnit.rawValue
        self.fpsMode = fpsMode.rawValue
        self.fpsValue = fpsValue
        self.outputCodec = outputCodec.rawValue
        self.qualityMode = qualityMode.rawValue
        self.qualityValue = qualityValue
        self.outputFolderMode = outputFolderMode.rawValue
        self.sampleRateMode = sampleRateMode.rawValue
        self.sampleRate = sampleRate.rawValue
        self.audioChannelMode = audioChannelMode.rawValue
        self.mergeOutputFilename = mergeOutputFilename
        self.mergeAspectMode = mergeAspectMode.rawValue
        self.mergeOutputCodec = mergeOutputCodec.rawValue
        self.mergeQualityMode = mergeQualityMode.rawValue
        self.mergeQualityValue = mergeQualityValue
        self.mergeFpsValue = mergeFpsValue
        self.gifResolutionMode = gifResolutionMode.rawValue
        self.gifScalePercent = gifScalePercent
        self.gifFixedWidth = gifFixedWidth
        self.gifCustomWidth = gifCustomWidth
        self.gifCustomHeight = gifCustomHeight
        self.gifFrameRate = gifFrameRate
        self.gifSpeedMultiplier = gifSpeedMultiplier
        self.gifLoopMode = gifLoopMode.rawValue
        self.gifLoopCount = gifLoopCount
        self.gifOutputFormat = gifOutputFormat.rawValue
        self.gifTextFontName = gifTextFontName
        self.parallelJobs = parallelJobs
    }
}
