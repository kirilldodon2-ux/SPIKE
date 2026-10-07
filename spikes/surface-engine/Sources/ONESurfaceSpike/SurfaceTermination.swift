import Foundation

// AppKit owns scheduling/reply. This gate only joins audio and an explicit MOV save.
struct SurfaceTerminationGate {
    private(set) var started = false
    private(set) var hasReplied = false
    private var audioFinished = false
    private var mirrorFinished = false
    var awaitingAudio: Bool { started && !audioFinished }

    mutating func begin(waitForMirror: Bool) -> Bool {
        guard !started else { return false }
        started = true
        mirrorFinished = !waitForMirror
        return true
    }

    mutating func audioDidFinish() -> Bool {
        guard started else { return false }
        audioFinished = true
        return takeReply()
    }

    mutating func mirrorDidFinish() -> Bool {
        guard started else { return false }
        mirrorFinished = true
        return takeReply()
    }

    private mutating func takeReply() -> Bool {
        guard audioFinished && mirrorFinished && !hasReplied else { return false }
        hasReplied = true
        return true
    }
}

func checkSurfaceTermination() {
    var idle = SurfaceTerminationGate()
    precondition(!idle.audioDidFinish() && !idle.mirrorDidFinish())
    precondition(idle.begin(waitForMirror: false) && !idle.begin(waitForMirror: false))
    precondition(idle.awaitingAudio && idle.audioDidFinish() && !idle.awaitingAudio)
    precondition(!idle.audioDidFinish() && !idle.mirrorDidFinish())

    var recording = SurfaceTerminationGate()
    precondition(recording.begin(waitForMirror: true))
    // Audio completion OR its deadline must not discard an unfinished MOV.
    precondition(!recording.audioDidFinish() && !recording.hasReplied)
    precondition(!recording.audioDidFinish() && recording.mirrorDidFinish())
    precondition(!recording.mirrorDidFinish())

    var mirrorFirst = SurfaceTerminationGate()
    precondition(mirrorFirst.begin(waitForMirror: true))
    precondition(!mirrorFirst.mirrorDidFinish() && mirrorFirst.awaitingAudio)
    precondition(mirrorFirst.audioDidFinish() && !mirrorFirst.audioDidFinish())
    print("Termination checks passed: async audio join, MOV hold in both orders, deadline/late completion, single reply")
}
