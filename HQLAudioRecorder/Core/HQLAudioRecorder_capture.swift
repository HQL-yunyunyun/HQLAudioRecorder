//
//  HQLAudioRecorder.swift
//  HQLAudioRecorder
//
//  Created by 何启亮 on 2023/4/6.
//

import Foundation
import AVFoundation
//import FirebaseCrashlytics



/// 使用 AVCapture 来录音的类
@objcMembers
@objc class HQLCaptureAudioRecorder: NSObject, AudioRecordProvider {
    
    // 状态
    public var status: HQLAudioRecorderStatus {
        get {
            return _status
        }
    }
    // 录音地址
    public var fileURL: URL
    // 录制时长 -> 只有在录制中才有值
    public var duration: CMTime {
        get {
            return _duration
        }
    }
    // 录制配置
    public var settings: [String: Any]?
    public let fileType: AVFileType
    
    public weak var delegate: HQLAudioRecorderDelegate?
    
    /// private
    private let _captureSession = AVCaptureSession()
    private let _audioOutput = AVCaptureAudioDataOutput()
    private var _assetWriter: AVAssetWriter?
    private var _audioInput: AVAssetWriterInput?
    
    private var _duration: CMTime = .zero // 时长
    private var _maxDuration: CMTime = .zero // 为0的时候，时长无限
    private var _status: HQLAudioRecorderStatus = .wait // 状态
    
    private let _audioQueue: DispatchQueue = DispatchQueue(label: "AudioRecorderQueue")
    private let _semaphoreLock = DispatchSemaphore(value: 1)
    
    // ==================MARK: - Init
    
    required init(fileURL: URL, settings: [String : Any]?, delegate: HQLAudioRecorderDelegate) {
        self.fileURL = fileURL
        self.fileType = .m4a
        super.init()
        
        let _ = self.configureCaptureSession()
        
        if let settings = settings {
            self.settings = settings
        } else {
            self.settings = self._audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType)
        }
        
        //        NTAudioRecorderHolder.shared.audioRecorder = self
    }
    
//    init(fileURL: URL, settings: [String: Any]?, fileType: AVFileType = .m4a) {
//        self.fileURL = fileURL
//        self.fileType = fileType
//        super.init()
//
//        let _ = self.configureCaptureSession()
//
//        if let settings = settings {
//            self.settings = settings
//        } else {
//            self.settings = self._audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: fileType)
//        }
//
//
//    }
    
//    deinit {
//        print("dealloc ---> "+self.className())
//    }
    
    // ==================MARK: -
    
    // 开始录音
    @objc public func record() -> Bool {
        return self.record(forDuration: 0.0)
    }
    
    @objc public func record(forDuration duration: TimeInterval) -> Bool {
        
        // 判断是否正在录制中 -> 判断writer的状态
        _semaphoreLock.wait()
        
//        Crashlytics.crashlytics().log("\(#function), status: \(String(_status.rawValue)), self: \(Unmanaged.passUnretained(self).toOpaque())")
        
        if _status == .finishing || _status == .recording{
            assert(false, "当前已正在结束中或者录制中")
            _semaphoreLock.signal()
            return false
        }
        if _assetWriter?.status == .writing {
            assert(false, "当前已正在录制中")
            _semaphoreLock.signal()
            return false
        }
        _status = .wait
        
        var duration = duration;
        if duration < 0 {
            duration = 0.0
        }
        
        // 最多的时长
        let rate = self.settings?[AVSampleRateKey] as? Int32
        let sampleRate: CMTimeScale = CMTimeScale(rate ?? 44100)
        let maxDur = CMTime.init(seconds: duration, preferredTimescale: sampleRate)
        _maxDuration = maxDur
        
        // 删除旧的音频文件（如果存在）
        let _ = self.deleteRecord()
        
        // 配置 AVAssetWriter
        do {
            _assetWriter = try AVAssetWriter(outputURL: fileURL, fileType: self.fileType)
            _audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: self.settings)
//            _audioInput?.preferredMediaChunkDuration = CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
            
            if let _audioInput = _audioInput, _assetWriter!.canAdd(_audioInput) {
                _assetWriter!.add(_audioInput)
            }
        } catch {
            print("Error configuring AVAssetWriter:", error)
            delegate?.audioRecorderReceiveError(self, error: error)
            
            _semaphoreLock.signal()
            
            return false
        }
        
        // 录音
//        NotificationCenter.default.post(name: .NTAudioBeginRecordNotificationName, object: nil)
        
        _duration = .zero
        _status = .recording
        // 开始捕获会话
        _audioQueue.async { [self] in
            _captureSession.startRunning()
        }
        
        _semaphoreLock.signal()
        return true
    }
    
    // 暂停录音
    @objc public func pause() {
        _semaphoreLock.wait()
        
//        Crashlytics.crashlytics().log("\(#function), status: \(String(_status.rawValue)), self: \(Unmanaged.passUnretained(self).toOpaque())")
        
        if _status == .finishing || _status == .wait {
            _semaphoreLock.signal()
            return
        }
        _status = .pause
        _audioQueue.async { [self] in
            _captureSession.stopRunning()
        }
        _semaphoreLock.signal()
    }
    
    // 恢复录音
    @objc func resume() {
        _semaphoreLock.wait()
        
//        Crashlytics.crashlytics().log("\(#function), status: \(String(_status.rawValue)), self: \(Unmanaged.passUnretained(self).toOpaque())")
        
        if _status == .finishing || _status == .recording {
            _semaphoreLock.signal()
            return
        }
        _status = .recording
        _audioQueue.async { [self] in
            _captureSession.startRunning()
        }
        _semaphoreLock.signal()
    }
    
    // 停止录音
    @objc func stop(_ completion: (() -> Void)?) {
        // 停止捕获会话
        _semaphoreLock.wait()
        
//        Crashlytics.crashlytics().log("\(#function), status: \(String(_status.rawValue)), self: \(Unmanaged.passUnretained(self).toOpaque())")
        
        if _status == .finishing {
            _semaphoreLock.signal()
            return
        }
        
        _status = .finishing
        _audioQueue.async { [self] in
            _captureSession.stopRunning()
        }
        
        // 完成写入
        if (_audioInput?.isReadyForMoreMediaData ?? false) == false {
            // 记录日志
//            Crashlytics.crashlytics().log("[AudioInput markAsFinished] when status is 0")
//            Crashlytics.crashlytics().log("[AssetWriter finishWriting] when status is \((_assetWriter?.status ?? .unknown).rawValue)")
            
//            let error = NSError(domain: "com.liftalk.audioRecorderErrordomain", code: -1, userInfo: [NSLocalizedDescriptionKey : "[AudioInput markAsFinished] when status is 0\n"+"[AssetWriter finishWriting] when status is \((_assetWriter?.status ?? .unknown).rawValue)"])
//            NTFIRCErrorRecordManager.recordError(error)
            self._semaphoreLock.signal()
            return
        }
        
        _audioInput?.markAsFinished()
        _assetWriter?.finishWriting { [weak self] in
            if let self = self {
                
                self._audioInput = nil
                self._assetWriter = nil
                
                self._status = .wait
                
                print("Finished writing audio to file:", self.fileURL)
                self.delegate?.audioRecorderDidFinishRecording(self)
                
                if let completion = completion {
                    completion()
                }
            }
        }
        
        self._semaphoreLock.signal()
    }
    
    @objc func deleteRecord() -> Bool {
        if _assetWriter?.status == .writing {
            assert(false, "正在录制中，不能删除源文件")
            return false
        }
        let path = self.fileURL.relativePath
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
        
        return true
    }
    
    @objc func stopRecordAndResetStatus() {
        // 直接暂停
        if _status == .recording {
            stop(nil)
        }
    }
    
    // ==================MARK: -
    
    /// config
    private func configureCaptureSession() -> Bool {
        // 查找默认音频设备
        
        _captureSession.automaticallyConfiguresApplicationAudioSession = false // 如果设为true，那么就会使用系统自动配置，这里会默认使用手机录音，而不是蓝牙耳机录音
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            return false
        }
        
        do {
            // 将音频设备包装在捕获设备输入中
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            
            // 如果可以添加输入，则将其添加到会话中
            if _captureSession.canAddInput(audioInput) {
                _captureSession.addInput(audioInput)
            }
            
            // 配置音频输出
            _audioOutput.setSampleBufferDelegate(self, queue: _audioQueue)
            if _captureSession.canAddOutput(_audioOutput) {
                _captureSession.addOutput(_audioOutput)
            }
        } catch {
            print("Error configuring capture session:", error)
            delegate?.audioRecorderReceiveError(self, error: error)
            return false
        }
        
        return true
    }
}

extension HQLCaptureAudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // 时长 -> 自加
        _duration = CMTimeAdd(_duration, CMSampleBufferGetDuration(sampleBuffer))
        
        // 配置
        if _assetWriter?.status == .unknown {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
//                let sampleRate = formatDescription.audioStreamBasicDescription?.mSampleRate ?? 44100
//                _assetWriter?.movieFragmentInterval = CMTime(value: 1, timescale: Int32(sampleRate))
                _assetWriter?.startWriting()
                _assetWriter?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
        }
        
        // 写入数据
        if _assetWriter?.status == .writing, let _audioInput = _audioInput, _audioInput.isReadyForMoreMediaData {
            _audioInput.append(sampleBuffer)
        }
        
        delegate?.audioRecorderRecordCallback(self)
        
        print("录制%f", CMTimeGetSeconds(_duration))
        // 判断时长
        if _maxDuration != .zero {
            if CMTimeCompare(_duration, _maxDuration) >= 0 {
                // 当前时长大于等于最大时长 -> 停止录制
                print("录制主动完成%f", CMTimeGetSeconds(_duration))
                self.stop(nil)
            }
        }
        
    }
}
