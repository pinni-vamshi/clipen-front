import AppKit
import AVFoundation

enum MediaTools {
    static let all: [ClipboardTool] = [
        ClipboardTool(
            id: "media.info",
            icon: "info.circle",
            label: "Paste Media Info",
            group: "INFO",
            preview: { item in
                guard let url = MediaService.mediaURL(for: item) else { return nil }
                return "Paste metadata for \(url.lastPathComponent)"
            },
            runAsync: { item in
                guard let url = MediaService.mediaURL(for: item) else { return nil }
                return .text(await MediaService.infoText(for: url))
            }
        ),
        ClipboardTool(
            id: "video.first-frame",
            icon: "photo",
            label: "Paste First Frame",
            group: "EXPORT",
            preview: { item in
                guard let url = MediaService.mediaURL(for: item),
                      FileKindDetector.isVideoFile(url) else { return nil }
                return "Create image from video"
            },
            runAsync: { item in
                guard let url = MediaService.mediaURL(for: item),
                      FileKindDetector.isVideoFile(url) else { return nil }
                return await MediaService.firstFrame(from: url)
            }
        )
    ]
}

enum MediaService {
    static func mediaURL(for item: ClipboardItem) -> URL? {
        let url: URL
        switch item.content {
        case .file(let u):
            url = u
        case .files(let urls) where urls.count == 1:
            url = urls[0]
        default:
            return nil
        }
        guard FileKindDetector.isMediaFile(url),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func infoText(for url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        var lines = [
            "Name: \(url.lastPathComponent)",
            "Path: \(url.path)"
        ]

        if let type = mediaKind(for: url) {
            lines.append("Type: \(type)")
        }
        if let size = fileSize(url) {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                lines.append("Duration: \(durationFormatter.string(from: seconds) ?? "\(Int(seconds))s")")
            }
        }

        if FileKindDetector.isVideoFile(url),
           let tracks = try? await asset.load(.tracks),
           let videoTrack = tracks.first(where: { $0.mediaType == .video }),
           let naturalSize = try? await videoTrack.load(.naturalSize),
           let transform = try? await videoTrack.load(.preferredTransform) {
            let transformed = naturalSize.applying(transform)
            lines.append("Resolution: \(Int(abs(transformed.width)))x\(Int(abs(transformed.height)))")
        }

        return lines.joined(separator: "\n")
    }

    static func firstFrame(from url: URL) async -> TransformOutput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .positiveInfinity

                do {
                    let cgImage: CGImage
                    do {
                        cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                    } catch {
                        cgImage = try generator.copyCGImage(
                            at: CMTime(seconds: 0.1, preferredTimescale: 600),
                            actualTime: nil
                        )
                    }
                    let image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    guard let pngData = image.pngData() else {
                        continuation.resume(returning: .status("Couldn't create video frame image."))
                        return
                    }
                    continuation.resume(returning: .item(
                        ClipboardItem(content: ClipboardContent.imageContent(rawData: pngData, dataType: .init("public.png"), fallback: image)!),
                        message: "Created first frame image."
                    ))
                } catch {
                    continuation.resume(returning: .status("Couldn't extract the first video frame."))
                }
            }
        }
    }

    private static func mediaKind(for url: URL) -> String? {
        if FileKindDetector.isVideoFile(url) { return "Video" }
        if FileKindDetector.isAudioFile(url) { return "Audio" }
        return nil
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
