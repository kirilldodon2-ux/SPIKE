import AppKit
import Darwin
import Foundation

@MainActor final class MediaRemoteAdapter: NSObject, AmbientMediaAdapter {
    var onSnapshot: ((AmbientMediaSnapshot) -> Void)?

    private typealias InfoBlock = @convention(block) (NSDictionary?) -> Void
    private typealias BoolBlock = @convention(block) (Bool) -> Void
    private typealias StringBlock = @convention(block) (NSString?) -> Void
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping InfoBlock) -> Void
    private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping BoolBlock) -> Void
    private typealias GetDisplayName = @convention(c) (Int32, DispatchQueue, @escaping StringBlock) -> Void
    private typealias Register = @convention(c) (DispatchQueue) -> Void
    private typealias Unregister = @convention(c) () -> Void
    private typealias SendCommand = @convention(c) (Int32, NSDictionary?) -> Bool

    private enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private let handle: UnsafeMutableRawPointer
    private let getInfo: GetInfo
    private let getPlaying: GetPlaying
    private let getDisplayName: GetDisplayName
    private let register: Register
    private let unregister: Unregister?
    private let sendCommand: SendCommand
    private var latestInfo: [String: Any] = [:]
    private var latestSource: String?
    private var isPlaying = false
    private var started = false

    private static let notificationNames = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
    ]

    init?(loadingSystemFramework: Void) {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW),
              let getInfo: GetInfo = Self.load("MRMediaRemoteGetNowPlayingInfo", from: handle),
              let getPlaying: GetPlaying = Self.load("MRMediaRemoteGetNowPlayingApplicationIsPlaying",
                                                     from: handle),
              let getDisplayName: GetDisplayName = Self.load("MRMediaRemoteGetNowPlayingApplicationDisplayName",
                                                             from: handle),
              let register: Register = Self.load("MRMediaRemoteRegisterForNowPlayingNotifications",
                                                 from: handle),
              let sendCommand: SendCommand = Self.load("MRMediaRemoteSendCommand", from: handle) else {
            return nil
        }
        self.handle = handle
        self.getInfo = getInfo
        self.getPlaying = getPlaying
        self.getDisplayName = getDisplayName
        self.register = register
        self.unregister = Self.load("MRMediaRemoteUnregisterForNowPlayingNotifications", from: handle)
        self.sendCommand = sendCommand
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        register(.main)
        for rawName in Self.notificationNames {
            NotificationCenter.default.addObserver(self, selector: #selector(mediaDidChange),
                                                   name: Notification.Name(rawName), object: nil)
        }
        refresh()
    }

    func stop() {
        guard started else { return }
        started = false
        NotificationCenter.default.removeObserver(self)
        unregister?()
    }

    func togglePlayback() { _ = sendCommand(Command.togglePlayPause.rawValue, nil) }
    func skipForward() { _ = sendCommand(Command.nextTrack.rawValue, nil) }
    func skipBackward() { _ = sendCommand(Command.previousTrack.rawValue, nil) }

    @objc private func mediaDidChange() {
        refresh()
    }

    private func refresh() {
        getInfo(.main) { [weak self] dictionary in
            guard let self else { return }
            latestInfo = dictionary as? [String: Any] ?? [:]
            publish()
        }
        getPlaying(.main) { [weak self] playing in
            guard let self else { return }
            isPlaying = playing
            publish()
        }
        getDisplayName(0, .main) { [weak self] name in
            guard let self else { return }
            latestSource = name as String?
            publish()
        }
    }

    private func publish() {
        let title = latestInfo["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        guard let title, !title.isEmpty else {
            onSnapshot?(.idle)
            return
        }

        let artist = latestInfo["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        let album = latestInfo["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        let artworkData = latestInfo["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let artwork = artworkData.flatMap(NSImage.init(data:))
        onSnapshot?(AmbientMediaSnapshot(state: isPlaying ? .playing : .paused,
                                         title: title,
                                         subtitle: artist ?? album,
                                         sourceName: latestSource,
                                         artwork: artwork))
    }

    private static func load<T>(_ name: String,
                                from handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
