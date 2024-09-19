//
//  HQLAudioRecorderProvider.swift
//  HQLAudioRecorder
//
//  Created by 何启亮 on 2023/8/25.
//

import Foundation
import AVFoundation

@objc enum HQLAudioRecorderStatus: NSInteger {
    case wait = 0
    case recording = 1
    case pause = 2
    case finishing = 3 // 正在停止
}

@objc protocol AudioRecordProvider: NSObjectProtocol {
    
    /// 当前的状态
    var status: HQLAudioRecorderStatus { get }
    /// 地址
    var fileURL: URL { get set }
    /// 时长
    var duration: CMTime { get }
    /// 录制配置
    var settings: [String: Any]? { get set }
    /// 代理
//    weak var delegate: HQLAudioRecorderDelegate? { get set }
    
    /// 初始化
    @objc init(fileURL: URL, settings: [String: Any]?, delegate: HQLAudioRecorderDelegate)
    
    /// 录音相关的方法
    @objc func record() -> Bool
    @objc func record(forDuration duration: TimeInterval) -> Bool
    @objc func pause()
    @objc func resume()
    @objc func stop(_ completion: (() -> Void)?)
    @objc func deleteRecord() -> Bool
    @objc func stopRecordAndResetStatus()
}

@objc protocol HQLAudioRecorderDelegate: NSObjectProtocol {
    // 完成录制
    func audioRecorderDidFinishRecording(_ recorder: AudioRecordProvider)
    // 错误
    func audioRecorderReceiveError(_ recorder: AudioRecordProvider, error: Error?)
    // 录制回调
    func audioRecorderRecordCallback(_ recorder: AudioRecordProvider)
}
