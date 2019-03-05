//
//  ViewController.swift
//  AVCaptureSample
//
//  Created by usayuki on 2019/03/04.
//  Copyright © 2019 usayuki. All rights reserved.
//

import AVFoundation
import Photos
import UIKit

class ViewController: UIViewController {

    private var session: AVCaptureSession!
    private var writer: AVAssetWriter!
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var frameCount: Int = 0
    private var firstTime: CMTime!
    private var imageView: UIImageView!
    private var label: UILabel!
    private var url: URL!
    
    @IBAction func startButtonTapped(_ sender: UIButton) {
        self.setup()
        
        self.session.startRunning()
        self.writer.startWriting()
        self.writer.startSession(atSourceTime: .zero)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
    }
    
    private func setup() {
        self.setupVideo()
        self.setupPreview()
        self.setupWriter()
        self.setupSynthesis()
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        self.write(sampleBuffer: sampleBuffer)
        
        if self.frameCount > 200 {
            self.session.stopRunning()
            self.writer.endSession(atSourceTime: CMTime(value: Int64(frameCount - 1) * 30, timescale: 30))
            self.writer.finishWriting(completionHandler: { () -> Void in
                self.saveMovie()
                
                for output in self.session.outputs {
                    self.session.removeOutput(output)
                }
                for input in self.session.inputs {
                    self.session.removeInput(input)
                }
                self.session = nil
                self.writer = nil
                
                self.frameCount = 0
            })
        }
    }
}

extension ViewController {
    private func setupVideo() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        
        self.session = AVCaptureSession()
        
        // 入力の設定
        let input = try! AVCaptureDeviceInput.init(device: device)
        self.session.addInput(input)
        
        // 出力の設定
        let output = AVCaptureVideoDataOutput()
        // ピクセルフォーマットを32bit BGR+Aにする
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue.main)
        // キューがブロックされているときに新しいフレームが来たら削除する
        output.alwaysDiscardsLateVideoFrames = true
        self.session.addOutput(output)
        
        for connection in output.connections {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    private func setupPreview() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        let frame = CGRect(x: 0, y: 0, width: self.view.frame.width, height: self.view.frame.height - 100)
        layer.frame = frame
        layer.videoGravity = .resizeAspectFill
        layer.connection?.videoOrientation = .portrait
        self.view.layer.addSublayer(layer)
    }
}

extension ViewController {
    private func setupWriter() {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(NSUUID().uuidString).mov")
        self.writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: self.view.frame.size.width,
            AVVideoHeightKey: self.view.frame.size.height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        self.writer.add(input)
        
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: self.view.frame.size.width,
            kCVPixelBufferHeightKey as String: self.view.frame.size.height
            ])
    }
    
    private func write(sampleBuffer: CMSampleBuffer) {
        if CMSampleBufferDataIsReady(sampleBuffer) {
            if self.writer.status == .writing {
                var info = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(self.frameCount), timescale: 30), decodeTimeStamp: .invalid)
                var copyBuffer: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copyBuffer)
                
                if self.frameCount == 0 {
                    self.firstTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                }
                
                if self.adaptor.assetWriterInput.isReadyForMoreMediaData {
                    let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let frameTime = CMTimeSubtract(timeStamp, self.firstTime)
                    let pxBuffer = self.synthesisImage(sampleBuffer: sampleBuffer)
                    self.adaptor.append(pxBuffer, withPresentationTime: frameTime)
                }
                
                self.frameCount += 1
            }
        }
    }
}

extension ViewController {
    private func setupSynthesis() {
        self.imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: self.view.frame.width, height: self.view.frame.height - 100))
        self.label = UILabel()
        self.label.center = self.view.center
        self.label.frame.size = CGSize(width: 100, height: 100)
        self.label.font = UIFont.systemFont(ofSize: 20)
    }
    
    private func synthesisImage(sampleBuffer: CMSampleBuffer) -> CVPixelBuffer {
        let image = self.uiImageFromCMSampleBuffer(sampleBuffer: sampleBuffer)
        let newImage = synthesis(image: image)
        let pixelBuffer = pixelBufferFromUIImage(image: newImage)
        return pixelBuffer
    }
    
    private func uiImageFromCMSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage {
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let image = UIImage(ciImage: ciImage)
        return image
    }
    
    private func pixelBufferFromUIImage(image: UIImage) -> CVPixelBuffer {
        let options = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(image.size.width), Int(image.size.height), kCVPixelFormatType_32ARGB, options as CFDictionary, &pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        
        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pixelData, width: Int(image.size.width), height: Int(image.size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.translateBy(x: 0, y: image.size.height)
        context.scaleBy(x: 1, y: -1)
        
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        
        return pixelBuffer!
    }
    
    private func synthesis(image: UIImage) -> UIImage {
        self.imageView.image = image
        self.label.text = String(frameCount)
        self.imageView.addSubview(self.label)
        
        UIGraphicsBeginImageContextWithOptions(self.imageView.frame.size, false, UIScreen.main.scale)
        
        let context = UIGraphicsGetCurrentContext()!
        self.imageView.layer.render(in: context)
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        
        for subview in self.imageView.subviews {
            subview.removeFromSuperview()
        }
        
        return newImage
    }
}

extension ViewController {
    private func saveMovie() {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.url)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    let alert = UIAlertController(title: "保存完了", message: "", preferredStyle: .alert)
                    let action: UIAlertAction = UIAlertAction(title: "OK", style: .default, handler: nil)
                    alert.addAction(action)
                    self.present(alert, animated: true, completion: nil)
                } else {
                    let alert = UIAlertController(title: "保存失敗", message: "", preferredStyle: .alert)
                    let action: UIAlertAction = UIAlertAction(title: "OK", style: .default, handler: nil)
                    alert.addAction(action)
                    self.present(alert, animated: true, completion: nil)
                }
            }
        })
    }
}
