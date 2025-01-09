import AVFoundation
import Flutter

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "video_compress", binaryMessenger: registrar.messenger()
        )
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            let bitrate = args!["bitRate"] as? Int
            compressVideo(
                path, quality, deleteOrigin, startTime, duration, includeAudio,
                frameRate, bitrate, result
            )
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getBitMap(
        _ path: String, _ quality: NSNumber, _ position: NSNumber, _: FlutterResult
    ) -> Data? {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }

        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true

        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position), preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }

    private func getByteThumbnail(
        _ path: String, _ quality: NSNumber, _ position: NSNumber, _ result: FlutterResult
    ) {
        if let bitmap = getBitMap(path, quality, position, result) {
            result(bitmap)
        }
    }

    private func getFileThumbnail(
        _ path: String, _ quality: NSNumber, _ position: NSNumber, _ result: FlutterResult
    ) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path, quality, position, result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(
                    FlutterError(
                        code: channelName, message: "getFileThumbnail error", details: "getFileThumbnail error"
                    )
                )
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }

    public func getMediaInfoJson(_ path: String) -> [String: Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }

        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset

        let orientation = avController.getVideoOrientation(path)

        let title = avController.getMetaDataByTag(metadataAsset, key: "title")
        let author = avController.getMetaDataByTag(metadataAsset, key: "author")

        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength

        let size = track.naturalSize.applying(track.preferredTransform)

        let width = abs(size.width)
        let height = abs(size.height)

        let dictionary =
            [
                "path": Utility.excludeFileProtocol(path),
                "title": title,
                "author": author,
                "width": width,
                "height": height,
                "duration": duration,
                "filesize": filesize,
                "orientation": orientation,
            ] as [String: Any?]
        return dictionary
    }

    private func getMediaInfo(_ path: String, _ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }

    @objc private func updateProgress(_ progress: Double) {
        if !stopCommand {
            var percentage = progress * 100
            if percentage > 100 {
                percentage = 100
            }
            channel.invokeMethod(
                "updateProgress", arguments: "\(String(describing: percentage))"
            )
        }
    }

    private func getExportPreset(_ quality: NSNumber, _ width: CGFloat, _ height: CGFloat) -> (
        Int, Int
    ) {
        let aspectRatio = width / height
        var newWidth: Int
        var newHeight: Int
        switch quality {
        case 1:
            newWidth = 720
            newHeight = 720
        case 2:
            newWidth = 360
            newHeight = 360
        case 3:
            newWidth = 640
            newHeight = 640
        case 4:
            newWidth = 1280
            newHeight = 720
        case 5:
            newWidth = 640
            newHeight = 480
        case 6:
            newWidth = 1280
            newHeight = 720
        case 7:
            newWidth = 1920
            newHeight = 720
        default:
            newWidth = 0
            newHeight = 0
        }

        if aspectRatio >= 1 {
            if newHeight > Int(height) {
                return (Int(width), Int(height))
            }
            return (Int(CGFloat(newHeight) * aspectRatio), newHeight)
        }
        if newWidth > Int(width) {
            return (Int(width), Int(height))
        }
        return (newWidth, Int(CGFloat(newWidth) / aspectRatio))
    }

    private func getComposition(
        _ isIncludeAudio: Bool, _ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack
    ) -> AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(
                withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }

        return composition
    }

    private func compressVideo(
        _ path: String, _ quality: NSNumber, _: Bool, _: Double?,
        _: Double?, _ includeAudio: Bool?, _ frameRate: Int?, _ bitrate: Int?,
        _ result: @escaping FlutterResult
    ) {
        // Generate output path
        let uuid = NSUUID().uuidString
        let compressionUrl = Utility.getPathUrl(
            "\(Utility.basePath())/\(Utility.getFileName(path))\(uuid).mp4")

        let sourceVideoUrl = Utility.getPathUrl(path)
        let video = avController.getVideoAsset(sourceVideoUrl)

        let destination = compressionUrl

        let videoAsset = avController.getVideoAsset(sourceVideoUrl)
        guard let videoTrack = videoAsset.tracks(withMediaType: AVMediaType.video).first else {
            result(
                FlutterError(code: "video_compress", message: "Failed to get video track.", details: nil))
            return
        }

        var newBitrate = Int(videoTrack.estimatedDataRate)

        if bitrate != nil && newBitrate > bitrate! {
            newBitrate = bitrate!
        }

        // Handle new width and height values
        let videoSize = videoTrack.naturalSize
        let size: (width: Int, height: Int) = getExportPreset(
            quality, videoSize.width, videoSize.height
        )

        let newWidth = size.width
        let newHeight = size.height

        // Total Frames
        let durationInSeconds = videoAsset.duration.seconds
        var newFrameRate = videoTrack.nominalFrameRate

        if frameRate != nil && Float(frameRate!) < newFrameRate {
            newFrameRate = Float(frameRate!)
        }
        let totalFrames = ceil(durationInSeconds * Double(videoTrack.nominalFrameRate))

        // Progress
        let totalUnits = Int64(totalFrames)

        // Setup video writer input
        let videoWriterInput = AVAssetWriterInput(
            mediaType: AVMediaType.video,
            outputSettings: getVideoWriterSettings(
                bitrate: newBitrate, width: newWidth, height: newHeight, frameRate: newFrameRate
            )
        )
        videoWriterInput.expectsMediaDataInRealTime = true
        videoWriterInput.transform = videoTrack.preferredTransform

        let videoWriter = try? AVAssetWriter(outputURL: destination, fileType: AVFileType.mov)
        videoWriter?.add(videoWriterInput)

        let writerAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: nil
        )

        // Setup video reader output
        let videoReaderSettings: [String: AnyObject] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) as AnyObject,
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack, outputSettings: videoReaderSettings
        )

        var videoReader: AVAssetReader?
        do {
            videoReader = try AVAssetReader(asset: videoAsset)
        } catch {
            result(
                FlutterError(code: "video_compress", message: error.localizedDescription, details: nil))
            return
        }

        let isIncludeAudio = includeAudio ?? true
        videoReader?.add(videoReaderOutput)
        // setup audio writer
        let audioWriterInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: nil)
        audioWriterInput.expectsMediaDataInRealTime = false
        videoWriter?.add(audioWriterInput)
        // setup audio reader
        let audioTrack = videoAsset.tracks(withMediaType: AVMediaType.audio).first
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if audioTrack != nil {
            audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack!, outputSettings: nil)
            audioReader = try? AVAssetReader(asset: videoAsset)
            audioReader?.add(audioReaderOutput!)
        }
        videoWriter?.startWriting()

        // start writing from video reader
        videoReader?.startReading()
        videoWriter?.startSession(atSourceTime: CMTime.zero)
        let processingQueue = DispatchQueue(label: "processingQueue1", qos: .background)

        var isFirstBuffer = true
        var frameCount = Int(0)
        videoWriterInput.requestMediaDataWhenReady(
            on: processingQueue,
            using: { () in
                while videoWriterInput.isReadyForMoreMediaData {
                    // Observe any cancellation
                    if self.stopCommand {
                        videoReader?.cancelReading()
                        videoWriter?.cancelWriting()
                        self.stopCommand = false
                        var json = self.getMediaInfoJson(path)
                        json["isCancel"] = true
                        let jsonString = Utility.keyValueToJson(json)
                        return result(jsonString)
                    }

                    // Update progress based on number of processed frames
                    let presentationTime: CMTime = CMTimeMake(
                        value: Int64(frameCount * (1000 / Int(newFrameRate))), timescale: 1000
                    )

                    frameCount += 1
                    self.updateProgress(Double(frameCount) / Double(totalFrames))

                    let sampleBuffer: CMSampleBuffer? = videoReaderOutput.copyNextSampleBuffer()

                    if videoReader?.status == .reading, sampleBuffer != nil {
                        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer!)
                        writerAdaptor.append(pixelBuffer!, withPresentationTime: presentationTime)
                    } else {
                        videoWriterInput.markAsFinished()
                        if videoReader?.status == .completed {
                            if audioReader != nil, isIncludeAudio {
                                if !(audioReader!.status == .reading) || !(audioReader!.status == .completed) {
                                    // start writing from audio reader
                                    audioReader?.startReading()
                                    videoWriter?.startSession(atSourceTime: CMTime.zero)
                                    let processingQueue = DispatchQueue(label: "processingQueue2", qos: .background)

                                    audioWriterInput.requestMediaDataWhenReady(
                                        on: processingQueue,
                                        using: {
                                            while audioWriterInput.isReadyForMoreMediaData {
                                                let sampleBuffer: CMSampleBuffer? = audioReaderOutput?
                                                    .copyNextSampleBuffer()
                                                if audioReader?.status == .reading, sampleBuffer != nil {
                                                    if isFirstBuffer {
                                                        let dict = CMTimeCopyAsDictionary(
                                                            CMTimeMake(value: 1024, timescale: 44100),
                                                            allocator: kCFAllocatorDefault
                                                        )
                                                        CMSetAttachment(
                                                            sampleBuffer as CMAttachmentBearer,
                                                            key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, value: dict,
                                                            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
                                                        )
                                                        isFirstBuffer = false
                                                    }
                                                    audioWriterInput.append(sampleBuffer!)
                                                } else {
                                                    audioWriterInput.markAsFinished()

                                                    videoWriter?.finishWriting {
                                                        var json = self.getMediaInfoJson(
                                                            Utility.excludeEncoding(compressionUrl.path))
                                                        json["isCancel"] = false
                                                        let jsonString = Utility.keyValueToJson(json)
                                                        result(jsonString)
                                                    }
                                                }
                                            }
                                        }
                                    )
                                }
                            } else {
                                videoWriter?.finishWriting {
                                    var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
                                    json["isCancel"] = false
                                    let jsonString = Utility.keyValueToJson(json)
                                    result(jsonString)
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    private func getVideoWriterSettings(bitrate: Int, width: Int, height: Int, frameRate: Float)
        -> [String: AnyObject]
    {
        let videoWriterCompressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate) as AnyObject,
        ]

        let videoWriterSettings: [String: AnyObject] = [
            AVVideoCodecKey: AVVideoCodecType.h264 as AnyObject,
            AVVideoCompressionPropertiesKey: videoWriterCompressionSettings as AnyObject,
            AVVideoWidthKey: width as AnyObject,
            AVVideoHeightKey: height as AnyObject,
        ]

        return videoWriterSettings
    }

    private func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        result("")
    }
}
