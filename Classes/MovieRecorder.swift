//
//  MovieRecorder.swift
//  VideoSnake
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/3/8.
//
//
/*
     File: MovieRecorder.h
     File: MovieRecorder.m
 Abstract: Real-time movie recorder which is totally non-blocking
  Version: 2.2

 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.

 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.

 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.

 Copyright (C) 2014 Apple Inc. All Rights Reserved.

 */


import UIKit

import CoreMedia

@objc(MovieRecorderDelegate)
protocol MovieRecorderDelegate: NSObjectProtocol {
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder)
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error)
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder)
}


import AVFoundation

//-DLOG_STATUS_TRANSITIONS
//Build Settings>Swift Compiler - Custom Flags>Other Swift Flags

private enum MovieRecorderStatus: Int {
    case idle = 0
    case preparingToRecord
    case recording
    // waiting for inflight buffers to be appended
    case finishingRecordingPart1
    // calling finish writing on the asset writer
    case finishingRecordingPart2
    // terminal state
    case finished
    // terminal state
    case failed
}   // internal state machine

#if LOG_STATUS_TRANSITIONS
    extension MovieRecorderStatus: CustomStringConvertible {
        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .preparingToRecord:
                return "PreparingToRecord"
            case .recording:
                return "Recording"
            case .finishingRecordingPart1:
                return "FinishingRecordingPart1"
            case .finishingRecordingPart2:
                return "FinishingRecordingPart2"
            case .finished:
                return "Finished"
            case .failed:
                return "Failed"
            }
        }
    }
#endif


@objc(MovieRecorder)
class MovieRecorder: NSObject {
    private var _status: MovieRecorderStatus = .idle
    
    private weak var _delegate: MovieRecorderDelegate?
    private var _delegateCallbackQueue: DispatchQueue!
    
    private var _writingQueue: DispatchQueue
    
    private var _URL: URL
    
    private var _assetWriter: AVAssetWriter?
    private var _haveStartedSession: Bool = false
    
    private var _audioTrackSourceFormatDescription: CMFormatDescription?
    private var _audioInput: AVAssetWriterInput?
    
    private var _videoTrackSourceFormatDescription: CMFormatDescription?
    private var _videoTrackTransform: CGAffineTransform
    private var _videoInput: AVAssetWriterInput?
    
    //MARK: -
    //MARK: API
    
    init(URL: Foundation.URL) {
        
        _writingQueue = DispatchQueue(label: "com.apple.sample.movierecorder.writing", attributes: [])
        _videoTrackTransform = CGAffineTransform.identity
        _URL = URL
        super.init()
    }
    
    // Only one audio and video track each are allowed.
    func addVideoTrackWithSourceFormatDescription(_ formatDescription: CMFormatDescription, transform: CGAffineTransform) {
        
        synchronized(self) {
            if _status != .idle {
                fatalError("Cannot add tracks while not idle")
            }
            
            if _videoTrackSourceFormatDescription != nil {
                fatalError("Cannot add more than one video track")
            }
            
            self._videoTrackSourceFormatDescription = formatDescription
            self._videoTrackTransform = transform
        }
    }
    
    func addAudioTrackWithSourceFormatDescription(_ formatDescription: CMFormatDescription) {
        
        synchronized(self) {
            if _status != .idle {
                fatalError("Cannot add tracks while not idle")
            }
            
            if _audioTrackSourceFormatDescription != nil {
                fatalError("Cannot add more than one audio track")
            }
            
            self._audioTrackSourceFormatDescription = formatDescription
        }
    }
    
    var delegate: MovieRecorderDelegate? {
        var myDelegate: MovieRecorderDelegate? = nil
        synchronized(self) {
            myDelegate = self._delegate
        }
        return myDelegate
    }
    
    // delegate is weak referenced
    func setDelegate(_ delegate: MovieRecorderDelegate?, callbackQueue delegateCallbackQueue: DispatchQueue?) {
        if delegate != nil && delegateCallbackQueue == nil {
            fatalError("Caller must provide a delegateCallbackQueue")
        }
        
        synchronized(self) {
            self._delegate = delegate
            self._delegateCallbackQueue = delegateCallbackQueue
        }
    }
    
    // Asynchronous, might take several hunderd milliseconds. When finished the delegate's recorderDidFinishPreparing: or recorder:didFailWithError: method will be called.
    func prepareToRecord() {
        synchronized(self) {
            if _status != .idle {
                fatalError("Already prepared, cannot prepare again")
            }
            
            self.transitionToStatus(.preparingToRecord, error: nil)
        }
        
        DispatchQueue.global(qos: .userInteractive).async {
            
            autoreleasepool {
                var error: Error? = nil
                do {
                    // AVAssetWriter will not write over an existing file.
                    try FileManager.default.removeItem(at: self._URL)
                } catch _ {}
                
                do {
                    self._assetWriter = try AVAssetWriter(outputURL: self._URL, fileType: AVFileTypeQuickTimeMovie)
                    
                    // Create and add inputs
                    if let videoFormat =  self._videoTrackSourceFormatDescription {
                        try self.setupAssetWriterVideoInput(videoFormat, transform: self._videoTrackTransform)
                    }
                    
                    if let audioFormat = self._audioTrackSourceFormatDescription {
                        try self.setupAssetWriterAudioInput(audioFormat)
                    }
                    
                    let success = self._assetWriter?.startWriting() ?? false
                    if success {
                        error = self._assetWriter?.error as NSError?
                    }
                } catch let error1 {
                    error = error1
                }
                
                synchronized(self) {
                    if error != nil {
                        self.transitionToStatus(.failed, error: error)
                    } else {
                        self.transitionToStatus(.recording, error: nil)
                    }
                }
            }
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaTypeVideo)
    }
    
    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime) {
        var sampleBuffer: CMSampleBuffer? = nil
        
        var timingInfo: CMSampleTimingInfo = CMSampleTimingInfo()
        timingInfo.duration = kCMTimeInvalid
        timingInfo.decodeTimeStamp = kCMTimeInvalid
        timingInfo.presentationTimeStamp = presentationTime
        
        let err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, _videoTrackSourceFormatDescription!, &timingInfo, &sampleBuffer)
        if sampleBuffer != nil {
            self.appendSampleBuffer(sampleBuffer!, ofMediaType: AVMediaTypeVideo)
        } else {
            let exceptionReason = "sample buffer create failed (\(err))"
            fatalError(exceptionReason)
        }
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaTypeAudio)
    }
    
    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishRecording: or recorder:didFailWithError: method will be called.
    func finishRecording() {
        synchronized(self) {
            var shouldFinishRecording = false
            switch _status {
            case .idle,
            .preparingToRecord,
            .finishingRecordingPart1,
            .finishingRecordingPart2,
            .finished:
                fatalError("Not recording")
            case .failed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                NSLog("Recording has failed, nothing to do")
            case .recording:
                shouldFinishRecording = true
            }
            
            if shouldFinishRecording {
                self.transitionToStatus(.finishingRecordingPart1, error: nil)
            } else {
                return
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                    if self._status != .finishingRecordingPart1 {
                        return
                    }
                    
                    // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                    // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
                    self.transitionToStatus(.finishingRecordingPart2, error: nil)
                }
                
                self._assetWriter?.finishWriting {
                    synchronized(self) {
                        let error = self._assetWriter?.error
                        if error != nil {
                            self.transitionToStatus(.failed, error: error)
                        } else {
                            self.transitionToStatus(.finished, error: nil)
                        }
                    }
                }
            }
        }
    }
    
    deinit {
        
        self.teardownAssetWriterAndInputs()
        
    }
    
    //MARK: -
    //MARK: Internal
    
    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofMediaType mediaType: String) {
        
        synchronized(self) {
            if _status.rawValue < MovieRecorderStatus.recording.rawValue {
                fatalError("Not ready to record yet")
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                    // Because of this we are lenient when samples are appended and we are no longer recording.
                    // Instead of throwing an exception we just release the sample buffers and return.
                    if self._status.rawValue > MovieRecorderStatus.finishingRecordingPart1.rawValue {
                        return
                    }
                }
                
                if !self._haveStartedSession {
                    self._assetWriter?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    self._haveStartedSession = true
                }
                
                let input = (mediaType == AVMediaTypeVideo) ? self._videoInput : self._audioInput
                
                if input?.isReadyForMoreMediaData ?? false {
                    let success = input!.append(sampleBuffer)
                    if !success {
                        let error = self._assetWriter?.error
                        synchronized(self) {
                            self.transitionToStatus(.failed, error: error)
                        }
                    }
                } else {
                    NSLog("%@ input not ready for more media data, dropping buffer", mediaType)
                }
            }
        }
    }
    
    // call under @synchonized( self )
    private func transitionToStatus(_ newStatus: MovieRecorderStatus, error: Error?) {
        var shouldNotifyDelegate = false
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("MovieRecorder state transition: %@->%@", _status.description, newStatus.description)
        #endif
        
        if newStatus != _status {
            // terminal states
            if newStatus == .finished || newStatus == .failed {
                shouldNotifyDelegate = true
                // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
                
                _writingQueue.async{
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .failed {
                        do {
                            try FileManager.default.removeItem(at: self._URL)
                        } catch _ {
                        }
                    }
                }
                
                #if LOG_STATUS_TRANSITIONS
                    if let error = error as NSError? {
                        NSLog("MovieRecorder error: \(error), code: \(error.code)")
                    }
                #endif
            } else if newStatus == .recording {
                shouldNotifyDelegate = true
            }
            
            _status = newStatus
        }
        
        if shouldNotifyDelegate && self.delegate != nil {
            _delegateCallbackQueue.async {
                
                autoreleasepool {
                    switch newStatus {
                    case .recording:
                        self.delegate!.movieRecorderDidFinishPreparing(self)
                    case .finished:
                        self.delegate!.movieRecorderDidFinishRecording(self)
                    case .failed:
                        self.delegate!.movieRecorder(self, didFailWithError: error!)
                    default:
                        break
                    }
                }
            }
        }
    }
    
    
    private func setupAssetWriterAudioInput(_ audioFormatDescription: CMFormatDescription) throws {
        let supportsFormatHint = AVAssetWriterInput.instancesRespond(to: #selector(AVAssetWriterInput.init(mediaType:outputSettings:sourceFormatHint:))) // supported on iOS 6 and later
        
        let audioCompressionSettings: [String : AnyObject]
        
        if supportsFormatHint {
            audioCompressionSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC.l as AnyObject,
            ]
        } else {
            let currentASBD = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDescription)
            
            var aclSize: size_t = 0
            let currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(audioFormatDescription, &aclSize)
            let currentChannelLayoutData: Data
            
            // AVChannelLayoutKey must be specified, but if we don't know any better give an empty data and let AVAssetWriter decide.
            if let currentChannelLayout = currentChannelLayout, aclSize > 0 {
                currentChannelLayoutData = Data(bytes: currentChannelLayout, count: aclSize)
            } else {
                currentChannelLayoutData = Data()
            }
            audioCompressionSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC.l as AnyObject,
                AVSampleRateKey: currentASBD!.pointee.mSampleRate as AnyObject,
                AVEncoderBitRatePerChannelKey: 64000 as AnyObject,
                AVNumberOfChannelsKey: Int(currentASBD!.pointee.mChannelsPerFrame) as AnyObject,
                AVChannelLayoutKey: currentChannelLayoutData as AnyObject,
            ]
        }
        if _assetWriter?.canApply(outputSettings: audioCompressionSettings, forMediaType: AVMediaTypeAudio) ?? false {
            if supportsFormatHint {
                _audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioCompressionSettings, sourceFormatHint: audioFormatDescription)
            } else {
                _audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioCompressionSettings)
            }
            _audioInput!.expectsMediaDataInRealTime = true
            if _assetWriter?.canAdd(_audioInput!) ?? false {
                _assetWriter!.add(_audioInput!)
            } else {
                throw type(of: self).cannotSetupInputError()
            }
        } else {
            throw type(of: self).cannotSetupInputError()
        }
    }
    
    private func setupAssetWriterVideoInput(_ videoFormatDescription: CMFormatDescription, transform: CGAffineTransform) throws {
        let supportsFormatHint = AVAssetWriterInput.instancesRespond(to: #selector(AVAssetWriterInput.init(mediaType:outputSettings:sourceFormatHint:))) // supported on iOS 6 and later
        
        var bitsPerPixel: Float
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription)
        let numPixels = dimensions.width * dimensions.height
        var bitsPerSecond: Int
        
        // Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
        if numPixels < 640 * 480 {
            bitsPerPixel = 4.05; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetMedium or Low.
        } else {
            bitsPerPixel = 10.1; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetHigh.
        }
        
        bitsPerSecond = Int(numPixels.f * bitsPerPixel)
        
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitsPerSecond,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ]
        
        let videoCompressionSettings: [String : Any] = [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        
        if _assetWriter?.canApply(outputSettings: videoCompressionSettings, forMediaType: AVMediaTypeVideo) ?? false {
            if supportsFormatHint {
                _videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoCompressionSettings, sourceFormatHint: videoFormatDescription)
            } else {
                _videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoCompressionSettings)
            }
            _videoInput!.expectsMediaDataInRealTime = true
            _videoInput!.transform = transform
            if _assetWriter?.canAdd(_videoInput!) ?? false {
                _assetWriter!.add(_videoInput!)
            } else {
                throw type(of: self).cannotSetupInputError()
            }
        } else {
            throw type(of: self).cannotSetupInputError()
        }
    }
    
    private class func cannotSetupInputError() -> Error {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment: "")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment: "")
        let errorDict: [AnyHashable: Any] = [NSLocalizedDescriptionKey : localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }
    
    private func teardownAssetWriterAndInputs() {
        _videoInput = nil
        _audioInput = nil
        _assetWriter = nil
    }
    
}
