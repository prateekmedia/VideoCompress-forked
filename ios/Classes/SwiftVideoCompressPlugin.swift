import Flutter
import AVFoundation

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
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
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
            compressVideo(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, result)
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
    
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }
        
        return composition    
    }
    
    private func compressVideo(_ path: String, _ quality: NSNumber, _ deleteOrigin: Bool, _ startTime: Double?,
                           _ duration: Double?, _ includeAudio: Bool?, _ frameRate: Int?,
                           _ result: @escaping FlutterResult) {
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        guard let sourceVideoTrack = avController.getTrack(sourceVideoAsset) else {
            print("Error: Unable to retrieve video track.")
            result(FlutterError(code: "video_compress", message: "Failed to get video track.", details: nil))
            return
        }
    
        // Generate output path
        let uuid = NSUUID().uuidString
        let compressionUrl = Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid).mp4")
    
        // Setup writer and inputs
        do {
            let videoWriter = try AVAssetWriter(outputURL: compressionUrl, fileType: .mp4)
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: sourceVideoTrack.naturalSize.width,
                AVVideoHeightKey: sourceVideoTrack.naturalSize.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_000_000, // Bitrate control (2 Mbps)
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264High40
                ]
            ]
    
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
    
            if let frameRate = frameRate {
                videoInput.mediaTimeScale = CMTimeScale(frameRate)
            }
    
            videoWriter.add(videoInput)
    
            // Audio setup if included
            let isIncludeAudio = includeAudio ?? true
            var audioInput: AVAssetWriterInput?
            if isIncludeAudio, let audioTrack = sourceVideoAsset.tracks(withMediaType: .audio).first {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44100,
                    AVEncoderBitRateKey: 128000
                ]
                audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                videoWriter.add(audioInput!)
            }
    
            // Start writing
            videoWriter.startWriting()
            videoWriter.startSession(atSourceTime: .zero)
    
            let reader = try AVAssetReader(asset: sourceVideoAsset)
            let videoReaderOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: nil)
            reader.add(videoReaderOutput)
    
            if isIncludeAudio, let audioTrack = sourceVideoAsset.tracks(withMediaType: .audio).first {
                let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                reader.add(audioReaderOutput)
            }
    
            reader.startReading()
    
            // Write video data
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoQueue")) {
                while videoInput.isReadyForMoreMediaData {
                    if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
                        videoInput.append(sampleBuffer)
                    } else {
                        videoInput.markAsFinished()
                        videoWriter.finishWriting {
                            result(Utility.excludeEncoding(compressionUrl.path))
                        }
                        break
                    }
                }
            }
        } catch {
            result(FlutterError(code: "video_compress", message: "Error initializing compression.", details: error.localizedDescription))
        }
    }
    
    private func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        exporter?.cancelExport()
        result("")
    }
    
}
