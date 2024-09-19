# Audio Recorder
录音过程中支持暂停/恢复录音，暂停过程中支持播放录音。
## 为什么要做这样一个功能？
因为系统的 AVAudioRecorder 不支持暂停过程中播放，而使用 AVCaptureSession + AVAssetWriter 也不支持这个功能，故使用 AVAudioRecorder + AVMutableComposition + AVAssetExportSession 来实现。
AVAudioRecorder 来录音，AVMutableComposition 来充当播放的playerItem，AVAssetExportSession来导出
