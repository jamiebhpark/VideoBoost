import Foundation
import CoreML
import AVKit

class VideoUpscaler {
    private let model: ESRGAN

    init?() {
        guard let model = try? ESRGAN(configuration: MLModelConfiguration()) else {
            print("Failed to load ESRGAN model")
            return nil
        }
        self.model = model
    }

    func upscaleVideo(inputURL: URL, completion: @escaping (URL?) -> Void) {
        print("Starting video upscale")
        let asset = AVAsset(url: inputURL)

        Task {
            do {
                _ = try await asset.load(.tracks)
                print("Tracks loaded")
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    print("Failed to get video track")
                    completion(nil)
                    return
                }

                let naturalSize = try await videoTrack.load(.naturalSize)
                print("Natural size loaded: \(naturalSize)")
                let readerOutputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]

                let reader = try AVAssetReader(asset: asset)
                let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
                reader.add(readerOutput)
                reader.startReading()

                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("output.mp4")
                print("Output URL: \(outputURL)")

                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

                let writerOutputSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: naturalSize.width * 4,
                    AVVideoHeightKey: naturalSize.height * 4
                ]
                let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
                writer.add(writerInput)

                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                var frameCount: Int64 = 0
                while reader.status == .reading {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                       let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                        let uiImage = UIImage(ciImage: ciImage)

                        guard let inputArray = try? MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32) else {
                            print("Failed to create MLMultiArray")
                            continue
                        }

                        guard let pixelBuffer = uiImage.pixelBuffer(width: 256, height: 256) else {
                            print("Failed to create pixel buffer")
                            continue
                        }

                        let modelInput = ESRGANInput(x: inputArray)

                        // 예측 수행
                        if let output = try? await self.model.prediction(input: modelInput) {
                            print("Model prediction successful")
                            // 디버깅용 출력
                            let outputArray = output.var_4047.dataPointer.assumingMemoryBound(to: Float.self)
                            for i in 0..<10 { // 출력의 앞 10개 값을 검사
                                print("Output value \(i): \(outputArray[i])")
                            }

                            guard let outputBuffer = self.mlmultiarrayToPixelBuffer(array: output.var_4047) else {
                                print("Failed to convert MLMultiArray to CVPixelBuffer")
                                continue
                            }
                            frameCount += 1
                            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
                            adaptor.append(outputBuffer, withPresentationTime: CMTime(value: frameCount, timescale: CMTimeScale(nominalFrameRate)))
                        } else {
                            print("Model prediction failed")
                        }
                    }
                }

                writer.finishWriting {
                    if writer.status == .completed {
                        print("Video upscaled successfully")
                        completion(outputURL)
                    } else {
                        print("Failed to upscale video")
                        completion(nil)
                    }
                }
            } catch {
                print("Error during video processing: \(error)")
                completion(nil)
            }
        }
    }

    func mlmultiarrayToPixelBuffer(array: MLMultiArray) -> CVPixelBuffer? {
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue

        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess else {
            print("Failed to create pixel buffer")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        guard let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!) else {
            print("Failed to get pixel buffer base address")
            return nil
        }

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            print("Failed to create CGContext")
            return nil
        }

        let dataPointer = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = dataPointer[offset]
                let g = dataPointer[offset + 1]
                let b = dataPointer[offset + 2]
                let a: Float32 = 255.0

                buffer[offset] = UInt8(clamping: Int((r.isFinite ? r : 0.0) * 255.0))
                buffer[offset + 1] = UInt8(clamping: Int((g.isFinite ? g : 0.0) * 255.0))
                buffer[offset + 2] = UInt8(clamping: Int((b.isFinite ? b : 0.0) * 255.0))
                buffer[offset + 3] = UInt8(a)
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        return pixelBuffer
    }
}

extension UIImage {
    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess else {
            print("Failed to create pixel buffer")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer!)

        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)

        context?.translateBy(x: 0, y: CGFloat(height))
        context?.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(context!)
        self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))

        return pixelBuffer
    }
}
