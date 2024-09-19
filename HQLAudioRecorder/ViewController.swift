//
//  ViewController.swift
//  HQLAudioRecorder
//
//  Created by 何启亮 on 2023/4/6.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var recordBtn: UIButton!
    @IBOutlet weak var pauseBtn: UIButton!
    @IBOutlet weak var playBtn: UIButton!
    @IBOutlet weak var tipsLabel: UILabel!
    
    private var hql_recorder: HQLAudioRecorder?

    private var player: AVPlayer?

    private var filePath: String {
        get {
            let path: String = NSTemporaryDirectory() + "test.m4a"
            return path
        }
    }

    private var fileUrl: URL {
        get {
            return NSURL.init(fileURLWithPath: self.filePath) as URL
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        PAirSandbox.sharedInstance().enableSwipe()
        
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord)
        try? AVAudioSession.sharedInstance().setActive(true)

        self.hql_recorder = HQLAudioRecorder(fileURL: self.fileUrl, sampleRate: 16000, delegate: self)
//        HQLAudioRecorder(fileURL: self.fileUrl, settings: nil, delegate: self)
//        HQLAudioRecorder(fileURL: self.fileUrl, settings: nil, fileType: .m4a)

        self.recordBtn.setTitle("录音", for: .normal)
        self.recordBtn.setTitle("停止", for: .selected)

        self.playBtn.setTitle("播放", for: .normal)
        self.playBtn.setTitle("停止播放", for: .selected)

        self.pauseBtn.isEnabled = false
        self.playBtn.isEnabled = false
    }

    
    @IBAction func onRecordBtnClick(_ sender: UIButton) {
        
        if (sender.isSelected) {
            // 录音中
            self.hql_recorder?.stop({
                // Do nothing...
            })

            self.pauseBtn.isEnabled = false
            self.playBtn.isEnabled = true
        } else {

            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord)
            
            if (self.hql_recorder?.status == .pause) {
                self.hql_recorder?.resume()
            } else {
                if FileManager.default.fileExists(atPath: self.filePath) {
                    try? FileManager.default.removeItem(atPath: self.filePath)
                }
                
                let _ = self.hql_recorder?.record()
            }

            self.pauseBtn.isEnabled = true
            self.playBtn.isEnabled = false
        }

        sender.isSelected = !sender.isSelected
    }
    
    @IBAction func onPauseBtnClick(_ sender: UIButton) {
        self.hql_recorder?.pause()
        
        self.recordBtn.isSelected = false
        self.playBtn.isEnabled = true
    }
    
    @IBAction func onPlayBtnClick(_ sender: UIButton) {
        if self.player == nil {
            self.player = AVPlayer()
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        if (sender.isSelected) {
            // 播放中
            self.player?.pause()
            self.recordBtn.isEnabled = true
        } else {
            let item = self.hql_recorder?.currentPlayerItem
            self.player?.replaceCurrentItem(with: item)
            self.player?.play()
            
            self.recordBtn.isEnabled = false
            self.pauseBtn.isEnabled = false
        }
        
        sender.isSelected = !sender.isSelected
    }
}

extension ViewController: HQLAudioRecorderDelegate {
    // 完成录制
    func audioRecorderDidFinishRecording(_ recorder: AudioRecordProvider) {
        
    }
    // 错误
    func audioRecorderReceiveError(_ recorder: AudioRecordProvider, error: Error?) {
        
    }
    // 录制回调
    func audioRecorderRecordCallback(_ recorder: AudioRecordProvider) {
        
    }
}
