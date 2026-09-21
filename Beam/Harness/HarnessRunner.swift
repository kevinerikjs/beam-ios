// HarnessRunner.swift
// Debug only. Turns this phone into the client half of the latency harness
// (beam-macos/tools/latency-harness) so the loop "input packet → Beacon → game →
// capture → encode → Wi-Fi → decode on this phone" is measured with no hands, on the
// real radio and the real decoder. Launched with arguments:
//
//   Beam -harness <host-ip> [presses] [interval_ms] [preset]
//
// against a Beacon in harness mode (BEACON_HARNESS=1). Stamps go to
// Documents/harness.log on the phone's clock: P (input packet with A down sent, id =
// press), H7 (frame assembled), H8 (decoded frame whose luma flipped), A (frame age
// from the clock sync), C (clock sample), DONE. The Mac-side analyzer reads P→H8.
//
// What it cannot see is the display: the frame is decoded, not shown, so "photon" is
// this plus the hand-off to the display layer and one refresh.

#if DEBUG
import CoreMedia
import Foundation
import Network
import Phoros
import PhorosInput
import PhorosMedia
import PhorosNetwork
import PhorosSession
import PhorosCore
import UIKit
import VideoToolbox

final class HarnessRunner {
    static var shared = HarnessRunner()
    /// True once a harness run was requested on the command line.
    static private(set) var isActive = false

    /// Starts when the launch arguments ask for it. Safe to call on every launch.
    static func startIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-harness"), i + 1 < args.count else { return }
        let host = args[i + 1]
        let presses = i + 2 < args.count ? Int(args[i + 2]) ?? 60 : 60
        let interval = i + 3 < args.count ? Int(args[i + 3]) ?? 600 : 600
        let preset = i + 4 < args.count ? QualityPreset(rawValue: args[i + 4]) ?? .p1080_60 : .p1080_60
        isActive = true
        shared = HarnessRunner(host: host)
        shared.start(host: host, presses: presses, intervalMs: interval, preset: preset)
    }

    private let secret = SharedSecret(hex: "5e1f2a9c4d7b3e6a8f0c1d2e3b4a5968778695a4b3c2d1e0f1e2d3c4b5a69788")!
    private var link: PhorosConnection?
    private var assembler = FrameAssembler()
    private var formatDescription: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var clock = ClockSync()
    private var clockTimer: DispatchSourceTimer?
    private var lastLuma: Double = -1
    private var flips = 0
    private var framesDecoded = 0
    private var pressID = 0
    private var presses = 0
    private var intervalMs = 600
    private var preset: QualityPreset = .p1080_60
    private let queue = DispatchQueue(label: "beam.harness", qos: .userInteractive)
    private let logQueue = DispatchQueue(label: "beam.harness.log")
    private var logHandle: FileHandle?
    private var rtcPeer: RealtimePeer?
    private var rtcTransport: PhorosPeerTransport?
    private var rtcReady = false
    private let host: String

    private init() { host = "" }
    private init(host: String) { self.host = host }

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("harness.log")
    }

    private func nowNanos() -> UInt64 {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom)
    }
    private func nowMicros() -> Int64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return Int64(Double(t.value) * 1_000_000 / Double(t.timescale))
    }
    private func log(_ stage: String, _ id: Int, extra: String = "") {
        let line = "\(stage),\(id),\(nowNanos())\(extra.isEmpty ? "" : "," + extra)\n"
        logQueue.async { self.logHandle?.write(line.data(using: .utf8)!) }
        if stage == "DONE" || stage == "END" { logQueue.async { self.uploadLog() } }
    }

    /// Pushes the whole log to the runner on the Mac (port 7990) once the run ends, so the
    /// result never depends on the developer tunnel copying files off the phone.
    private var uploaded = false
    private func uploadLog() {
        guard !uploaded, let data = try? Data(contentsOf: Self.logURL) else { return }
        uploaded = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 7990, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
            }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: self.logQueue)
    }

    private func start(host: String, presses: Int, intervalMs: Int, preset: QualityPreset) {
        self.presses = presses; self.intervalMs = intervalMs; self.preset = preset
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: Self.logURL)
        log("START", 0, extra: "\(host),\(UIScreen.main.maximumFramesPerSecond)")
        UIApplication.shared.isIdleTimerDisabled = true
        startKeepAwakeIfRequested()
        startTCPSinkIfRequested(host: host)

        let capabilities = ClientCapabilities(
            deviceName: "Harness iPhone", deviceID: "harness-client",
            audioCodecs: [.pcmFloat32], videoCodecs: [.hevc, .h264], wantsAudio: false,
            maximumFrameRate: Double(UIScreen.main.maximumFramesPerSecond)
        )
        connect(host: host, capabilities: capabilities, attempt: 1)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.formatDescription == nil else { return }
            log("DONE", 0, extra: "no video within 30 s")
        }
    }

    private var connected = false
    /// A fresh launch sometimes never completes the TCP handshake (the SYN leaves before the
    /// phone's radio is fully up after the tunnel activity); a connection that is not ready
    /// within 4 s is dropped and made again, three times.
    private func connect(host: String, capabilities: ClientCapabilities, attempt: Int) {
        let link = PhorosConnection(to: .hostPort(host: NWEndpoint.Host(host), port: 7979), parameters: PhorosConnection.parameters(), queue: queue)
        self.link = link
        link.onReady = { [weak self] in
            guard let self else { return }
            connected = true
            log("CONNECTED", attempt)
            link.send(try! JSONEncoder().encode(capabilities.authRequest(secret: secret)))
        }
        link.onEnd = { [weak self] reason in self?.log("END", 0, extra: "\(reason)") }
        link.onFrame = { [weak self] frame in self?.handle(frame) }
        link.start()
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.connected, attempt < 4 else { return }
            log("RETRY", attempt)
            link.onEnd = nil
            link.cancel()
            self.connect(host: host, capabilities: capabilities, attempt: attempt + 1)
        }
    }

    private func send(_ message: ControlMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        link?.send(data)
    }

    private func handle(_ frame: Frame) {
        switch frame {
        case .packet(let packet):
            switch packet.header.type {
            case .video, .videoKeyframe:
                if let assembled = assembler.receive(packet.payload, isKeyframe: packet.header.type == .videoKeyframe) {
                    log("H7", Int(assembled.frameNumber), extra: "\(assembled.presentationTimestamp),\(assembled.bitstream.count)")
                    if let age = clock.age(ofPresentationTimestamp: assembled.presentationTimestamp, now: nowMicros()) {
                        log("A", Int(assembled.frameNumber), extra: "\(age)")
                    }
                    decode(assembled)
                }
            case .parameterSets:
                guard let codec = VideoCodecID(packetFlags: packet.header.flags),
                      let description = VideoFormat.makeDescription(parameterSets: packet.payload, codec: codec) else { return }
                formatDescription = description
                makeDecoder(description)
                log("PS", 0, extra: codec.wireName)
            case .control:
                handleJSON(packet.payload)
            default: break
            }
        case .message(let json):
            handleJSON(json)
        }
    }

    private func handleJSON(_ data: Data) {
        if let pairing = try? JSONDecoder().decode(PairingMessage.self, from: data), pairing.type == .authSuccess || pairing.type == .authFailed {
            switch PairingClient.interpret(pairing) {
            case .authenticated(let host, _, _, _):
                log("AUTH", 0, extra: "controller=\(host.supportsControllerInput),clock=\(host.supportsClockSync)")
                send(.qualityRequest(preset))
                if host.supportsClockSync {
                    let t = DispatchSource.makeTimerSource(queue: queue)
                    t.schedule(deadline: .now() + 0.5, repeating: 0.25)
                    t.setEventHandler { [weak self] in
                        guard let self else { return }
                        send(.clockProbe(clock.probe(now: nowMicros())))
                    }
                    t.resume(); clockTimer = t
                }
                // Attach a controller: one neutral connected report, then presses.
                sendReport(a: false)
                // 8 s: the devicectl launch tunnel makes the Mac scan all Wi-Fi bands for
                // ~3.5 s; the presses start after that blackout has passed.
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.press() }
            case .failed(let reason):
                log("DONE", 0, extra: "auth failed: \(reason)")
            default: break
            }
            return
        }
        if let control = try? JSONDecoder().decode(ControlMessage.self, from: data) {
            if case .transportOffer(let offer) = control, offer.kind == "rtc2" { acceptRTC(offer) }
            if case .clockReply(let reply) = control, let rtt = clock.reply(reply, now: nowMicros()) {
                log("C", Int(rtt), extra: "\(clock.offset ?? 0),\(clock.bestRoundTrip ?? 0)")
            }
            if case .ping = control { send(.pong) }
        }
    }

    // MARK: rtc2: accept the host's UDP transport, take video and send input on it

    private func acceptRTC(_ offer: TransportOffer) {
        // Bind on the interface that reaches the host: loopback for a host on this machine
        // (the simulator shares the Mac's stack), else the address of our TCP side.
        let ours = "\(host == "127.0.0.1" ? "127.0.0.1" : localAddressTowardHost()):7982"
        guard let peer = RealtimePeer(isHost: false, localAddress: ours) else { log("RTC", 0, extra: "peer failed"); return }
        let media = PhorosPeerTransport(peer: peer, queue: queue)
        media.onReady = { [weak self] in self?.rtcReady = true; self?.log("RTC", 1) }
        media.onInbound = { [weak self] inbound in
            guard let self else { return }
            switch inbound {
            case .video(let assembled):
                // -ackvideo: a tiny uplink send in reaction to every received frame, the way
                // TCP acks arrive; an experiment on the phone's transmit-path state.
                if self.ackVideo, let t = self.rtcTransport { t.sendInput(self.lastReport, connected: true) }
                log("H7", Int(assembled.frameNumber), extra: "\(assembled.presentationTimestamp),\(assembled.bitstream.count)")
                if let age = clock.age(ofPresentationTimestamp: assembled.presentationTimestamp, now: nowMicros()) { log("A", Int(assembled.frameNumber), extra: "\(age)") }
                decode(assembled)
            case .videoParameterSets(let sets, let codec):
                guard let description = VideoFormat.makeDescription(parameterSets: sets, codec: codec) else { return }
                formatDescription = description
                makeDecoder(description)
                log("PS", 1, extra: codec.wireName)
            default: break
            }
        }
        rtcPeer = peer
        rtcTransport = media
        // -udpclass <0|3|4>: the peer socket's service class (best effort, video, voice)
        if let i = CommandLine.arguments.firstIndex(of: "-udpclass"), i + 1 < CommandLine.arguments.count, let c = Int32(CommandLine.arguments[i + 1]) {
            peer.setServiceClass(c); log("UDPCLASS", Int(c))
        }
        guard peer.runOwnSocket() == 0 else { log("RTC", 0, extra: "bind failed"); return }
        peer.setRemote(info: offer.info, address: offer.address, nowMicros: 0)
        send(.transportAnswer(TransportOffer(kind: "rtc2", address: ours, info: peer.localInfo)))
        log("RTC", 2, extra: ours)
    }

    private func localAddressTowardHost() -> String {
        if let path = link?.connection.currentPath, let endpoint = path.localEndpoint, case .hostPort(let h, _) = endpoint {
            return "\(h)".split(separator: "%").first.map(String.init) ?? "0.0.0.0"
        }
        return "0.0.0.0"
    }

    // MARK: Input: the press is an .input packet with A down, as a paired controller would send.

    /// -tcpsink <port>: opens a TCP connection to the host and discards everything it sends,
    /// a second bulk TCP flow next to the video (experiment: is the uplink tax about UDP or
    /// about downlink rate).
    private var sink: NWConnection?
    private func startTCPSinkIfRequested(host: String) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-tcpsink"), i + 1 < args.count, let port = UInt16(args[i + 1]) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        sink = c
        func drain() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, done, error in
                if done || error != nil { return }
                drain()
            }
        }
        c.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.log("SINK", Int(port)); drain() } }
        c.start(queue: queue)
    }

    private var lastReport = ControllerReport()
    private var keepAwakeTimer: DispatchSourceTimer?
    /// -keepawake <ms>: resends the current controller state every so often, an experiment
    /// to keep the phone's radio out of power save (uplink traffic is what an AP counts).
    private func startKeepAwakeIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-keepawake"), i + 1 < args.count, let ms = Int(args[i + 1]), ms > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(ms), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // With -dualinput each resend is a numbered probe on both pipes; the host logs
            // which copy arrived first and by how much (H2W/H2X), this side logs the send.
            var report = self.lastReport
            if self.dualInput { self.inputSequence &+= 1; report.sequence = self.inputSequence; self.log("KA", Int(self.inputSequence)) }
            if self.rtcReady, let t = self.rtcTransport { t.sendInput(report, connected: true); if !self.dualInput { return } }
            self.link?.send(Packet.encode(.input, flags: ControllerReport.connectedFlag, payload: report.serialized()))
        }
        timer.resume(); keepAwakeTimer = timer
        log("KEEPAWAKE", ms)
    }

    /// -dualinput: every report goes on rtc2 and on the TCP link, numbered; the host takes
    /// the first copy. The plain mode sends on rtc2 alone once it is up.
    private lazy var dualInput = CommandLine.arguments.contains("-dualinput")
    private lazy var ackVideo = CommandLine.arguments.contains("-ackvideo")
    private var inputSequence: UInt16 = 0

    private func sendReport(a: Bool) {
        var report = ControllerReport()
        if a { report.buttons.insert(.a) }
        if dualInput { inputSequence &+= 1; report.sequence = inputSequence }
        lastReport = report
        if rtcReady, let rtcTransport {
            rtcTransport.sendInput(report, connected: true)
            if !dualInput { return }
        }
        link?.send(Packet.encode(.input, flags: ControllerReport.connectedFlag, payload: report.serialized()))
    }

    private func press() {
        pressID += 1
        if pressID > presses {
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                log("DONE", 0, extra: "decoded=\(framesDecoded),flips=\(flips)")
                logQueue.sync {}
            }
            return
        }
        log("P", pressID, extra: "down")
        sendReport(a: true)
        queue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self else { return }
            log("P", pressID, extra: "up")   // the flash flips on down only
            sendReport(a: false)
            // send -> wire delay of the down report, from the core (rtc2 only)
            if let peer = self.rtcPeer, self.rtcReady { let w = peer.wireDelay(); log("WIRE", pressID, extra: "\(w.last),\(w.max)") }
        }
        let jitter = Double(Int.random(in: -150...150)) / 1000
        queue.asyncAfter(deadline: .now() + Double(intervalMs) / 1000 + jitter) { [weak self] in self?.press() }
    }

    // MARK: Decode and detect

    private func makeDecoder(_ description: CMVideoFormatDescription) {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, frameRefcon, status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer, let refcon, let frameRefcon else { return }
            let runner = Unmanaged<HarnessRunner>.fromOpaque(refcon).takeUnretainedValue()
            runner.detect(imageBuffer, frameNumber: Int(bitPattern: frameRefcon))
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: nil,
                                     imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session)
        decoder = session
    }

    private func decode(_ frame: AssembledFrame) {
        guard let formatDescription, let decoder,
              let sample = VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: formatDescription,
                                                        presentationTime: CMTime(value: CMTimeValue(frame.presentationTimestamp), timescale: 1_000_000)) else { return }
        var flags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: UnsafeMutableRawPointer(bitPattern: Int(frame.frameNumber)), infoFlagsOut: &flags)
    }

    private func detect(_ imageBuffer: CVImageBuffer, frameNumber: Int) {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0), height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else { return }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, n = 0
        for y in stride(from: max(0, height / 2 - 100), to: min(height, height / 2 + 100), by: 4) {
            for x in stride(from: max(0, width / 2 - 100), to: min(width, width / 2 + 100), by: 4) { sum += Int(p[y * rowBytes + x]); n += 1 }
        }
        let luma = Double(sum) / Double(max(1, n))
        framesDecoded += 1
        if framesDecoded % 120 == 1 { log("L", frameNumber, extra: String(format: "%.0f,%dx%d", luma, width, height)) }
        if lastLuma >= 0, abs(luma - lastLuma) > 60 {
            flips += 1
            log("H8", frameNumber, extra: String(format: "%.0f", luma))
        }
        lastLuma = luma
    }
}
#endif
