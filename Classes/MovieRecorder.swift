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
    func movieRecorderDidFinishPreparing(recorder: MovieRecorder)
    func movieRecorder(recorder: MovieRecorder, didFailWithError error: NSError)
    func movieRecorderDidFinishRecording(recorder: MovieRecorder)
}


import AVFoundation

//-DLOG_STATUS_TRANSITIONS
//Build Settings>Swift Compiler - Custom Flags>Other Swift Flags

private enum MovieRecorderStatus: Int {
    case Idle = 0
    case PreparingToRecord
    case Recording
    // waiting for inflight buffers to be appended
    case FinishingRecordingPart1
    // calling finish writing on the asset writer
    case FinishingRecordingPart2
    // terminal state
    case Finished
    // terminal state
    case Failed
}   // internal state machine

#if LOG_STATUS_TRANSITIONS
    extension MovieRecorderStatus: Printable {
        var description: String {
            switch self {
            case .Idle:
                return "Idle"
            case .PreparingToRecord:
                return "PreparingToRecord"
            case .Recording:
                return "Recording"
            case .FinishingRecordingPart1:
                return "FinishingRecordingPart1"
            case .FinishingRecordingPart2:
                return "FinishingRecordingPart2"
            case .Finished:
                return "Finished"
            case .Failed:
                return "Failed"
            }
        }
    }
#endif


@objc(MovieRecorder)
class MovieRecorder: NSObject {
    private var _status: MovieRecorderStatus = .Idle
    
    private weak var _delegate: MovieRecorderDelegate?
    private var _delegateCallbackQueue: dispatch_queue_t!
    
    private var _writingQueue: dispatch_queue_t
    
    private var _URL: NSURL
    
    private var _assetWriter: AVAssetWriter?
    private var _haveStartedSession: Bool = false
    
    private var _audioTrackSourceFormatDescription: CMFormatDescription?
    private var _audioInput: AVAssetWriterInput?
    
    private var _videoTrackSourceFormatDescription: CMFormatDescription?
    private var _videoTrackTransform: CGAffineTransform
    private var _videoInput: AVAssetWriterInput?
    
    //MARK: -
    //MARK: API
    
    init(URL: NSURL) {
        
        _writingQueue = dispatch_queue_create("com.apple.sample.movierecorder.writing", DISPATCH_QUEUE_SERIAL)
        _videoTrackTransform = CGAffineTransformIdentity
        _URL = URL
        super.init()
    }
    
    // Only one audio and video track each are allowed.
    func addVideoTrackWithSourceFormatDescription(formatDescription: CMFormatDescription, transform: CGAffineTransform) {
        
        synchronized(self) {
            if _status != .Idle {
                fatalError("Cannot add tracks while not idle")
            }
            
            if _videoTrackSourceFormatDescription != nil {
                fatalError("Cannot add more than one video track")
            }
            
            self._videoTrackSourceFormatDescription = formatDescription
            self._videoTrackTransform = transform
        }
    }
    
    func addAudioTrackWithSourceFormatDescription(formatDescription: CMFormatDescription) {
        
        synchronized(self) {
            if _status != .Idle {
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
    func setDelegate(delegate: MovieRecorderDelegate?, callbackQueue delegateCallbackQueue: dispatch_queue_t?) {
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
            if _status != .Idle {
                fatalError("Already prepared, cannot prepare again")
            }
            
            self.transitionToStatus(.PreparingToRecord, error: nil)
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)) {
            
            autoreleasepool {
                var error: NSError? = nil
                // AVAssetWriter will not write over an existing file.
                NSFileManager.defaultManager().removeItemAtURL(self._URL, error: nil)
                
                self._assetWriter = AVAssetWriter(URL: self._URL, fileType: AVFileTypeQuickTimeMovie, error: &error)
                
                // Create and add inputs
                if error == nil && self._videoTrackSourceFormatDescription != nil {
                    self.setupAssetWriterVideoInput(self._videoTrackSourceFormatDescription!, transform: self._videoTrackTransform, error: &error)
                }
                
                if error == nil && self._audioTrackSourceFormatDescription != nil {
                    self.setupAssetWriterAudioInput(self._audioTrackSourceFormatDescription!, error: &error)
                }
                
                if error == nil {
                    let success = self._assetWriter?.startWriting() ?? false
                    if success {
                        error = self._assetWriter?.error
                    }
                }
                
                synchronized(self) {
                    if error != nil {
                        self.transitionToStatus(.Failed, error: error)
                    } else {
                        self.transitionToStatus(.Recording, error: nil)
                    }
                }
            }
        }
    }
    
    func appendVideoSampleBuffer(sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaTypeVideo)
    }
    
    func appendVideoPixelBuffer(pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime) {
        var umSampleBuffer: Unmanaged<CMSampleBuffer>? = nil
        var sampleBuffer: CMSampleBuffer? = nil
        
        var timingInfo: CMSampleTimingInfo = CMSampleTimingInfo()
        timingInfo.duration = kCMTimeInvalid
        timingInfo.decodeTimeStamp = kCMTimeInvalid
        timingInfo.presentationTimeStamp = presentationTime
        
        let err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, _videoTrackSourceFormatDescription, &timingInfo, &umSampleBuffer)
        if umSampleBuffer != nil {
            self.appendSampleBuffer(umSampleBuffer!.takeRetainedValue(), ofMediaType: AVMediaTypeVideo)
        } else {
            let exceptionReason = "sample buffer create failed (\(err))"
            fatalError(exceptionReason)
        }
    }
    
    func appendAudioSampleBuffer(sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaTypeAudio)
    }
    
    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishRecording: or recorder:didFailWithError: method will be called.
    func finishRecording() {
        synchronized(self) {
            var shouldFinishRecording = false
            switch _status {
            case .Idle,
            .PreparingToRecord,
            .FinishingRecordingPart1,
            .FinishingRecordingPart2,
            .Finished:
                fatalError("Not recording")
            case .Failed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                NSLog("Recording has failed, nothing to do")
            case .Recording:
                shouldFinishRecording = true
            }
            
            if shouldFinishRecording {
                self.transitionToStatus(.FinishingRecordingPart1, error: nil)
            } else {
                return
            }
        }
        
        dispatch_async(_writingQueue) {
            
            autoreleasepool {
                synchronized(self) {
                    // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                    if self._status != .FinishingRecordingPart1 {
                        return
                    }
                    
                    // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                    // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
                    self.transitionToStatus(.FinishingRecordingPart2, error: nil)
                }
                
                self._assetWriter?.finishWritingWithCompletionHandler {
                    synchronized(self) {
                        let error = self._assetWriter?.error
                        if error != nil {
                            self.transitionToStatus(.Failed, error: error)
                        } else {
                            self.transitionToStatus(.Finished, error: nil)
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
    
    private func appendSampleBuffer(sampleBuffer: CMSampleBuffer, ofMediaType mediaType: String) {
        
        synchronized(self) {
            if _status.rawValue < MovieRecorderStatus.Recording.rawValue {
                fatalError("Not ready to record yet")
            }
        }
        
        dispatch_async(_writingQueue) {
            
            autoreleasepool {
                synchronized(self) {
                    // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                    // Because of this we are lenient when samples are appended and we are no longer recording.
                    // Instead of throwing an exception we just release the sample buffers and return.
                    if self._status.rawValue > MovieRecorderStatus.FinishingRecordingPart1.rawValue {
                        return
                    }
                }
                
                if !self._haveStartedSession {
                    self._assetWriter?.startSessionAtSourceTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    self._haveStartedSession = true
                }
                
                let input = (mediaType == AVMediaTypeVideo) ? self._videoInput : self._audioInput
                
                if input?.readyForMoreMediaData ?? false {
                    let success = input!.appendSampleBuffer(sampleBuffer)
                    if !success {
                        let error = self._assetWriter?.error
                        synchronized(self) {
                            self.transitionToStatus(.Failed, error: error)
                        }
                    }
                } else {
                    NSLog("%@ input not ready for more media data, dropping buffer", mediaType)
                }
            }
        }
    }
    
    // call under @synchonized( self )
    private func transitionToStatus(newStatus: MovieRecorderStatus, error: NSError?) {
        var shouldNotifyDelegate = false
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("MovieRecorder state transition: %@->%@", _status.description, newStatus.description)
        #endif
        
        if newStatus != _status {
            // terminal states
            if newStatus == .Finished || newStatus == .Failed {
                shouldNotifyDelegate = true
                // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
                
                dispatch_async(_writingQueue){
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .Failed {
                        NSFileManager.defaultManager().removeItemAtURL(self._URL, error: nil)
                    }
                }
                
                #if LOG_STATUS_TRANSITIONS
                    if error != nil {
                    NSLog("MovieRecorder error: %@, code: %i", error!, Int32(error!.code))
                    }
                #endif
            } else if newStatus == .Recording {
                shouldNotifyDelegate = true
            }
            
            _status = newStatus
        }
        
        if shouldNotifyDelegate && self.delegate != nil {
            dispatch_async(_delegateCallbackQueue) {
                
                autoreleasepool {
                    switch newStatus {
                    case .Recording:
                        self.delegate!.movieRecorderDidFinishPreparing(self)
                    case .Finished:
                        self.delegate!.movieRecorderDidFinishRecording(self)
                    case .Failed:
                        self.delegate!.movieRecorder(self, didFailWithError: error!)
                    default:
                        break
                    }
                }
            }
        }
    }
    
    
    private func setupAssetWriterAudioInput(audioFormatDescription: CMFormatDescription, error errorOut: NSErrorPointer) -> Bool {
        let supportsFormatHint = AVAssetWriterInput.instancesRespondToSelector("initWithMediaType:outputSettings:sourceFormatHint:") // supported on iOS 6 and later
        
        let audioCompressionSettings: [NSObject: AnyObject]
        
        if supportsFormatHint {
            audioCompressionSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
            ]
        } else {
            let currentASBD = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDescription)
            
            var aclSize: size_t = 0
            let currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(audioFormatDescription, &aclSize)
            let currentChannelLayoutData: NSData
            
            // AVChannelLayoutKey must be specified, but if we don't know any better give an empty data and let AVAssetWriter decide.
            if currentChannelLayout != nil && aclSize > 0 {
                currentChannelLayoutData = NSData(bytes: currentChannelLayout, length: aclSize)
            } else {
                currentChannelLayoutData = NSData()
            }
            audioCompressionSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: currentASBD.memory.mSampleRate,
                AVEncoderBitRatePerChannelKey: 64000,
                AVNumberOfChannelsKey: Int(currentASBD.memory.mChannelsPerFrame),
                AVChannelLayoutKey: currentChannelLayoutData,
            ]
        }
        if _assetWriter?.canApplyOutputSettings(audioCompressionSettings, forMediaType: AVMediaTypeAudio) ?? false {
            if supportsFormatHint {
                _audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioCompressionSettings, sourceFormatHint: audioFormatDescription)
            } else {
                _audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioCompressionSettings)
            }
            _audioInput!.expectsMediaDataInRealTime = true
            if _assetWriter?.canAddInput(_audioInput) ?? false {
                _assetWriter!.addInput(_audioInput)
            } else {
                if errorOut != nil {
                    errorOut.memory = self.dynamicType.cannotSetupInputError()
                }
                return false
            }
        } else {
            if errorOut != nil {
                errorOut.memory = self.dynamicType.cannotSetupInputError()
            }
            return false
        }
        
        return true
    }
    
    private func setupAssetWriterVideoInput(videoFormatDescription: CMFormatDescription, transform: CGAffineTransform, error errorOut: NSErrorPointer) -> Bool {
        let supportsFormatHint = AVAssetWriterInput.instancesRespondToSelector("initWithMediaType:outputSettings:sourceFormatHint:") // supported on iOS 6 and later
        
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
        
        let compressionProperties: NSDictionary = [
            AVVideoAverageBitRateKey: bitsPerSecond,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ]
        
        let videoCompressionSettings: [NSObject: AnyObject] = [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        
        if _assetWriter?.canApplyOutputSettings(videoCompressionSettings, forMediaType: AVMediaTypeVideo) ?? false {
            if supportsFormatHint {
                _videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoCompressionSettings, sourceFormatHint: videoFormatDescription)
            } else {
                _videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: videoCompressionSettings)
            }
            _videoInput!.expectsMediaDataInRealTime = true
            _videoInput!.transform = transform
            if _assetWriter?.canAddInput(_videoInput) ?? false {
                _assetWriter!.addInput(_videoInput)
            } else {
                if errorOut != nil {
                    errorOut.memory = self.dynamicType.cannotSetupInputError()
                }
                return false
            }
        } else {
            if errorOut != nil {
                errorOut.memory = self.dynamicType.cannotSetupInputError()
            }
            return false
        }
        
        return true
    }
    
    private class func cannotSetupInputError() -> NSError {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment: "")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment: "")
        let errorDict: [NSObject : AnyObject] = [NSLocalizedDescriptionKey : localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }
    
    private func teardownAssetWriterAndInputs() {
        _videoInput = nil
        _audioInput = nil
        _assetWriter = nil
    }
    
}