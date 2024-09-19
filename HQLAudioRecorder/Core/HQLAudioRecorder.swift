//
//  HQLAudioRecorder.swift
//  HQLAudioRecorder
//
//  Created by 何启亮 on 2023/8/25.
//

import Foundation
import AVFoundation

/**
 录音: 使用 AVAudioEncoder 来录音，AudioFile来写入文件，AAC来编码
 */
@objcMembers
class HQLAudioRecorder: NSObject, AudioRecordProvider {
    
    /// 录音状态
    var status: HQLAudioRecorderStatus {
        get {
            _status
        }
    }
    var fileURL: URL
    var duration: CMTime {
        get {
            CMTime(seconds: _duration, preferredTimescale: CMTimeScale(self.sampleRate))
        }
    }
    var settings: [String : Any]?
    
    /// 获取当前录音的playerItem
    var currentPlayerItem: AVPlayerItem? {
        get {
            _playerItem
        }
    }
    
    /// private
    private weak var delegate: HQLAudioRecorderDelegate?
    private var _duration: TimeInterval = 0 // 时长
    private var _maxDuration: TimeInterval = 0 // 为0的时候，时长无限
    private var _status: HQLAudioRecorderStatus = .wait // 状态
    private let sampleRate: Double
    private var _playerItem: AVPlayerItem?
    
    private let _semaphoreLock = DispatchSemaphore(value: 1)
    private let _queue = DispatchQueue(label: "AudioRecorder.queue")
    
    private var currentComposition: AVMutableComposition? // 合并录音的composition
    private var currentRecordIndex = 0 // 记录当前正在录音的index
    
    private var recorder: AVAudioRecorder? // 录音的实例
    private var recordingUrl: URL? // 正在录音的URL

    private var timer: Timer?// 计时的timer
    private var startTime: TimeInterval = 0 // 记录startTime
    
    /// 调用stopAndMerger的回调
    private var stopAndMergerCallback: (() -> Void)?
    
    // MARK: - Init
    
    required init(fileURL: URL, settings: [String : Any]?, delegate: HQLAudioRecorderDelegate) {
        
        self.fileURL = fileURL
        self.settings = settings
        self._status = .wait
        
        if self.settings == nil {
            // 设置一个默认的setting
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey : AVAudioQuality.high.rawValue
            ]
            self.settings = aacSettings
        }
        self.delegate = delegate
        
        if FileManager.default.fileExists(atPath: fileURL.relativePath) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        if let sampleRate = self.settings?[AVSampleRateKey] as? Double {
            self.sampleRate = sampleRate
        } else {
            assert(false, "sampleRate not set")
            self.sampleRate = 44100
            self.settings?[AVSampleRateKey] = 44100
        }
        
        super.init()
    }
    
    convenience init(fileURL: URL, sampleRate: Double, delegate: HQLAudioRecorderDelegate) {
        
        let settings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderAudioQualityKey : AVAudioQuality.low.rawValue
        ] as [String : Any]
        
        self.init(fileURL: fileURL, settings: settings, delegate: delegate)
    }
    
    deinit {
        self.endTimer()
        self.recorder?.stop()
        self.recorder = nil
    }
    
    // MARK: - record
    
    func record() -> Bool {
        return self.record(forDuration: 0.0)
    }
    
    func record(forDuration duration: TimeInterval) -> Bool {
        
        // 每次都需要判断状态
        _semaphoreLock.wait()
        
        if _status == .finishing || _status == .recording{
            assert(false, "当前已正在结束中或者录制中")
            _semaphoreLock.signal()
            return false
        }
        _status = .wait
        
        // 最多的时长
        var duration = duration;
        if duration < 0 {
            duration = 0.0
        }
        _maxDuration = duration
        
        // 删除旧的音频文件（如果存在）
        self.reset()
        
        _duration = 0
        currentRecordIndex = 0
        if self.startRecord(Index: currentRecordIndex) == false {
            _semaphoreLock.signal()
            return false
        }
        
        _duration = .zero
        _status = .recording
        
        _semaphoreLock.signal()
        return true
    }
    
    func pause() {
        _semaphoreLock.wait()
        
        if _status == .finishing || _status == .wait {
            _semaphoreLock.signal()
            return
        }
        _status = .pause
        stopAndMergerCurrentRecord(true) {
            // Do nothing...
        }
        
        _semaphoreLock.signal()
    }
    
    func resume() {
        _semaphoreLock.wait()
        
        if _status == .finishing || _status == .recording {
            _semaphoreLock.signal()
            return
        }
        _status = .recording
        currentRecordIndex += 1
        let _ = self.startRecord(Index: currentRecordIndex)
        
        _semaphoreLock.signal()
    }
    
    func stop(_ completion: (() -> Void)?) {
        _semaphoreLock.wait()
        
        // 调用stop方法，先调用 endTimer
        self.endTimer()
        
        if _status == .finishing {
            _semaphoreLock.signal()
            return
        }
        
        _status = .finishing
        // 转码
        stopAndMergerCurrentRecord(true) { [weak self] in
            guard let self = self else {
                return
            }
            self.export { [weak self] err in
                guard let self = self else {
                    return
                }
                self._semaphoreLock.wait()
                self._status = .wait
                self._semaphoreLock.signal()
                if let err = err {
                    // 错误
                    self.triggerError(err)
                } else {
                    // 成功
                    self.delegate?.audioRecorderDidFinishRecording(self)
                }
                if let completion = completion {
                    completion()
                }
            }
        }
        
        self._semaphoreLock.signal()
    }
    
    func deleteRecord() -> Bool {
        if self.status == .finishing {
            assert(false, "正在录制中，不能删除源文件")
            return false
        }

        let path = self.fileURL.relativePath
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
        
        if FileManager.default.fileExists(atPath: self.tempDir()) {
            try? FileManager.default.removeItem(atPath: self.tempDir())
        }
        
        return true
    }
    
    /// 结束录音并重置状态
    func stopRecordAndResetStatus() {
        if _status == .recording {
            stopAndMergerCurrentRecord(false, completion: nil)
        }
        if _status == .finishing {
            // 正在结束 / 导出
            self.reset(false)
        } else {
            self.reset(true)
        }
        
    }
    
    // MARK: - MergerAudio
    
    // 停止并合并当前的录音
    private func stopAndMergerCurrentRecord(_ needMerger: Bool, completion: (() -> Void)?) {
        
        // 没有在录音
        if recorder == nil || (recorder?.isRecording ?? false) == false {
            recorder = nil
            completion?()
            return
        }
        // 在录音 - 停止
        recorder?.stop()
        if needMerger == false {
            stopAndMergerCallback = nil
        } else {
            stopAndMergerCallback = completion
        }
    }
    
    private func startRecord(Index: Int) -> Bool {
        
        // 移除信息
        let path = tempPath(Index)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        
        let url = NSURL.fileURL(withPath: path)
        do {
            try recorder = AVAudioRecorder.init(url: url, settings: self.settings!)
            recordingUrl = url
        } catch {
            // 报错的error
            self.triggerError(error)
            return false
        }
        recorder?.delegate = self
        
        if (recorder?.prepareToRecord() ?? false) == false {
            // 报错的error
            return false
        }
        
        if (recorder?.record() ?? false) == false {
            // 报错的error
            return false
        }
        self.startTime = CACurrentMediaTime()
        self.startTimer()
        return true
    }
    
    /// 导出
    private func export(_ completion: @escaping (Error?) -> Void) {
        guard let currentComposition = currentComposition else {
            completion(NSError(domain: "hql.audiorecorder.export.error", code: -1000, userInfo: [
                NSLocalizedDescriptionKey : "Unknown error"
            ]))
            return
        }
        guard let exportSession = AVAssetExportSession(asset: currentComposition, presetName: AVAssetExportPresetAppleM4A) else {
            completion(NSError(domain: "hql.audiorecorder.export.error", code: -1000, userInfo: [
                NSLocalizedDescriptionKey : "Unknown error"
            ]))
            return
        }
        
        exportSession.outputURL = self.fileURL
        exportSession.outputFileType = .m4a
        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                // 完成
                completion(nil)
                return
            }
            if let error = exportSession.error {
                completion(error)
            }
        }
    }
    
    // MARK: - Tool
    
    /// 获取临时语音的文件
    private func tempPath(_ index: Int) -> String {
        return self.tempDir()+"/\(index).m4a"
    }
    
    /// 临时语音文件的目录
    private func tempDir() -> String {
        let temDirectoryPath = NSTemporaryDirectory()+"audio_temp_dir"
        if FileManager.default.fileExists(atPath: temDirectoryPath) == false {
            try? FileManager.default.createDirectory(atPath: temDirectoryPath, withIntermediateDirectories: true)
        }
        return temDirectoryPath
    }
    
    private func reset(_ deleteFile: Bool = true) {
        currentComposition = AVMutableComposition()
        if deleteFile {
            try? FileManager.default.removeItem(atPath: self.tempDir())
        }
        currentRecordIndex = 0
        _status = .wait
        recorder = nil
        recordingUrl = nil
    }
    
    private func triggerError(_ error: Error?) {
        delegate?.audioRecorderReceiveError(self, error: error)
        self.reset()
    }
    
    // MARK: - Timer
    
    private func startTimer() {
        self.endTimer()
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                return
            }
            if self.timer == nil {
                return
            }
            // 增加时间
            let cur = CACurrentMediaTime()
            let dur = cur - self.startTime
            self.startTime = cur
            self._duration += dur
            
            self.delegate?.audioRecorderRecordCallback(self)
            
            // 判断最大时长
            if self._duration >= self._maxDuration && self._maxDuration > 0 {
                // 停止
                self.stop(nil)
            }
        }
    }
    
    private func endTimer() {
        if let timer = timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    
}

extension HQLAudioRecorder: AVAudioRecorderDelegate {
    // 结束
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Do nothing...
        
        guard let currentComposition = currentComposition else {
            return
        }
        self.recorder = nil
        recordingUrl = nil
        self.endTimer()
        
        if stopAndMergerCallback == nil {
            return
        }
        
        // 根据当前index获取音频
        let path = self.tempPath(currentRecordIndex)
        let url = NSURL.fileURL(withPath: path)
        let asset = AVURLAsset(url: url)
        // 插入
        var audioTrack = currentComposition.track(withTrackID: 10)
        if audioTrack == nil {
            audioTrack = currentComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: 10)
        }
        guard let audioTrack = audioTrack, let assetTrack = asset.tracks(withMediaType: .audio).first else {
            self.triggerError(NSError(domain: "hql.audiorecorder.export.error", code: -1000, userInfo: [
                NSLocalizedDescriptionKey : "Unknown error"
            ]))
            return
        }
        
        var startTime = currentComposition.duration
        if startTime == .invalid {
            startTime = .zero
        }
        do {
            try audioTrack.insertTimeRange(CMTimeRange(start: CMTime.zero, duration: asset.duration), of: assetTrack, at: startTime)
            
            // 更新playerItem
            _playerItem = AVPlayerItem(asset: currentComposition)
        } catch {
            self.triggerError(error)
        }
        
        self.stopAndMergerCallback?()
        self.stopAndMergerCallback = nil
    }
    
    // error
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        // 结束timer
        self.endTimer()
        self.triggerError(error)
    }
}
