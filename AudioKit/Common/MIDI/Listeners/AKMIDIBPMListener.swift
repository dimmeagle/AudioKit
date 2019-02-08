//
//  AKMIDIBPMListener.swift
//  AudioKit
//
//  Created by Kurt Arnlund on 1/18/19.
//  Copyright © 2019 AudioKit. All rights reserved.
//
//  MIDI Spec
//      24 clocks/quarternote
//      96 clocks/4_beat_measure
//
//  Ideas
//      - Provide the standard deviation of differences in clock times to observe stability
//
//  Looked at
//      https://stackoverflow.com/questions/9641399/ios-how-to-receive-midi-tempo-bpm-from-host-using-coremidi
//      https://stackoverflow.com/questions/13562714/calculate-accurate-bpm-from-midi-clock-in-objc-with-coremidi
//      https://github.com/yderidde/PGMidi/blob/master/Sources/PGMidi/PGMidiSession.mm#L186


import Foundation
import CoreMIDI

public typealias BPMType = TimeInterval

/// A AudioKit midi listener that looks at midi clock messages and calculates a BPM
///
/// Usage:
///
///     let bpmListener = AKMIDIBPMListener()
///     AudioKit.midi.addListener(bpmListener)
///
/// Make your class a AKMIDIBPMObserver and you will recieve callbacks when the BPM
/// changes.
///
///     class YOURCLASS : AKMIDIBPMObserver {
///         func bpmUpdate(_ bpm: BpmType, bpmStr: String) {  ... }
///         func midiClockSlaveMode() { ... }
///         func midiClockMasterEnabled() { ... }
///
/// midiClockSlaveMode() informs client that midi clock messages have been received
/// and the client may not become the clock master.
///
/// midiClockMasterEnabled() informs client that midi clock messages have not been seen
/// in 1.6 seconds and the client is allowed to become the clock master.
///
open class AKMIDIBPMListener : NSObject {

    public var clockListener: AKMIDIClockListener?

    public var srtListener = AKMIDISRTListener()

    var bpmObservers: [AKMIDIBPMObserver] = []

    public var bpmStr: String = ""
    public var bpm: BPMType = 0
    var clockEvents: [UInt64] = []
    let clockEventLimit = 2
    var bpmStats = BPMHistoryStatistics()
    var bpmAveraging: BPMHistoryAveraging
    var timebaseInfo = mach_timebase_info()
    var tickSmoothing: ValueSmoothing
    var bpmSmoothing: ValueSmoothing

    var clockTimeout: AKMIDITimeout?
    public var incomingClockActive = false

    let BEAT_TICKS = 24
    let oneThousand = UInt64(1000)

    @objc public init(smoothing: Float64 = 0.8, bpmHistoryLimit: Int = 3) {
        assert(bpmHistoryLimit > 0, "You must specify a positive number for bpmHistoryLimit")
        tickSmoothing = ValueSmoothing(factor: smoothing)
        bpmSmoothing = ValueSmoothing(factor: smoothing)
        bpmAveraging = BPMHistoryAveraging(countLimit: bpmHistoryLimit)

        super.init()

        clockListener = AKMIDIClockListener(srtListener: srtListener, bpmListener: self)

        if timebaseInfo.denom == 0 {
            _ = mach_timebase_info(&timebaseInfo)
        }

        clockTimeout = AKMIDITimeout(timeoutInterval: 1.6, onMainThread: true, success: {}, timeout: {
            if self.incomingClockActive == true {
                self.midiClockActivityStopped()
            }
            self.incomingClockActive = false
        })
        midiClockActivityStopped()
    }

    deinit {
        clockTimeout = nil
        clockListener = nil
    }
}

// MARK: - BPM Analysis

public extension AKMIDIBPMListener {
    func analyze() {
        guard clockEvents.count > 1 else { return }
        guard clockEventLimit > 1 else { return }
        guard clockEvents.count >= clockEventLimit else { return}

        let previousClockTime = clockEvents[ clockEvents.count - 2 ]
        let currentClockTime = clockEvents[ clockEvents.count - 1 ]

        guard previousClockTime > 0 && currentClockTime > previousClockTime else { return }

        let clockDelta = currentClockTime - previousClockTime

        if timebaseInfo.denom == 0 {
            _ = mach_timebase_info(&timebaseInfo)
        }
        let intervalNanos = Float64(clockDelta * UInt64(timebaseInfo.numer)) / Float64(UInt64(oneThousand) * UInt64(timebaseInfo.denom))

        //NSEC_PER_SEC
        let oneMillion = Float64(USEC_PER_SEC)
        let bpmCalc = ((oneMillion / intervalNanos / Float64(BEAT_TICKS)) * Float64(60.0)) + 0.055
        //debugPrint("interval: ",intervalNanos)

        resetClockEventsLeavingOne()

        bpmStats.record(bpm: bpmCalc, time: currentClockTime)

        // bpmSmoothing.smoothed(
        let results = bpmStats.bpmFromRegressionAtTime(bpmStats.timeAt(ratio: 0.8)) // currentClockTime - 500000

        // Only report results when there is enough history to guess at the BPM
        let bpmToRecord : BPMType
        if results > 0 {
            bpmToRecord = BPMType(results)
        } else {
            bpmToRecord = BPMType(bpmCalc)
        }

        bpmAveraging.record(bpmToRecord)
        bpm = bpmAveraging.results.avg

        let newBpmStr = String(format: "%3.2f", bpm)
        if newBpmStr != bpmStr {
            bpmStr = newBpmStr

            bpmUpdate(bpmAveraging.results.avg, str: bpmStr)
        }
    }

    func resetClockEventsLeavingOne() {
        guard clockEvents.count > 1 else { return }
        clockEvents = clockEvents.dropFirst(clockEvents.count-1).map { $0 }
    }

    func resetClockEventsLeavingHalf() {
        guard clockEvents.count > 1 else { return }
        clockEvents = clockEvents.dropFirst(clockEvents.count/2).map { $0 }
    }

    func resetClockEventsLeavingNone() {
        guard clockEvents.count > 1 else { return }
        clockEvents = []
    }
}

// MARK: - AKMIDIBPMListener should be used as an AKMIDIListener

extension AKMIDIBPMListener : AKMIDIListener {

    public func receivedMIDISystemCommand(_ data: [MIDIByte], time: MIDITimeStamp = 0) {
        if data[0] == AKMIDISystemCommand.clock.rawValue {
            clockTimeout?.succeed()
            clockTimeout?.perform {
                if self.incomingClockActive == false {
                    midiClockActivityStarted()
                    self.incomingClockActive = true
                }
                clockEvents.append(time)
                analyze()
                clockListener?.midiClockBeat()
            }
        }
        if data[0] == AKMIDISystemCommand.stop.rawValue {
            resetClockEventsLeavingNone()
        }
        if data[0] == AKMIDISystemCommand.start.rawValue {
            resetClockEventsLeavingOne()
        }
        srtListener.receivedMIDISystemCommand(data, time: time)
    }
}

// MARK: - Management and Communications for BPM Observers

public extension AKMIDIBPMListener {
    public func addObserver(_ observer: AKMIDIBPMObserver) {
        bpmObservers.append(observer)
    }

    public func removeObserver(_ observer: AKMIDIBPMObserver) {
        bpmObservers.removeAll { $0 == observer }
    }

    public func removeAllObserver() {
        bpmObservers.removeAll()
    }

    func midiClockActivityStarted() {
        bpmObservers.forEach { (observer) in
            observer.midiClockSlaveMode()
        }
    }

    func midiClockActivityStopped() {
        bpmObservers.forEach { (observer) in
            observer.midiClockMasterEnabled()
        }
    }

    func bpmUpdate(_ bpm: BPMType, str: String) {
        bpmObservers.forEach { (observer) in
            observer.bpmUpdate(bpm, bpmStr: str)
        }
    }
}
