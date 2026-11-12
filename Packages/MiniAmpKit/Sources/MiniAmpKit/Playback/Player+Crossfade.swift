import AVFoundation

/// The end of a track, held back from the node until it's known whether it crossfades.
struct ReservedTail {
    let item: Int
    let file: TrackFile
    /// The first frame not scheduled.
    let start: AVAudioFramePosition
}

/// Crossfading, in DSP mode (see Crossfade for how the fade itself is made).
///
/// Each track is scheduled up to a point some seconds before its end: the crossfade's length
/// plus room to find the silence and the beat. Five seconds before that point, the rest of the
/// track and the start of the next are read and mixed off the main actor; then the track's
/// remainder up to the fade, the fade, and the next track from after it are scheduled back to
/// back. When there's no crossfade to do (another format, the same album, nothing next), the
/// remainder goes on as it is and the next track joins gaplessly, as without crossfade.
extension Player {
    /// The outgoing track's last stretch analysed for the fade, beyond the fade itself.
    static let crossfadeSlack = 20.0
    /// A held-back end is at least this far after where scheduling starts (a seek near the
    /// end), so there's time to prepare the fade.
    static let crossfadeMinimumLead = 7.0
    /// Seconds before the held-back end by which the fade must be ready.
    static let crossfadeDeadline = 2.0

    var crossfadeActive: Bool { graphHasDSP && crossfadeDuration > 0 }

    /// Stops the node and drops everything scheduled, held back, or being prepared.
    func resetScheduling() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        reservedTail = nil
        nextReservedTail = nil
        scheduler.reset()
    }

    /// Schedules `file` from `frame`, holding back its end when it may crossfade. Returns
    /// what was held back.
    func scheduleTrack(_ file: TrackFile, from frame: AVAudioFramePosition, item: Int,
                       continues: Bool = false) -> ReservedTail? {
        if crossfadeActive, file.kind == .pcm {
            let rate = file.sampleRate
            let nominal = file.length - AVAudioFramePosition((crossfadeDuration + Self.crossfadeSlack) * rate)
            let start = max(nominal, frame + AVAudioFramePosition(Self.crossfadeMinimumLead * rate))
            // At least a second left to fade over.
            if start < file.length - AVAudioFramePosition(rate) {
                scheduler.append(file, from: frame, to: start, token: item, continues: continues)
                return ReservedTail(item: item, file: file, start: start)
            }
        }
        scheduler.append(file, from: frame, token: item, continues: continues)
        return nil
    }

    /// Schedules a held-back end as it is.
    func scheduleRest(of tail: ReservedTail) {
        scheduler.append(tail.file, from: tail.start, token: tail.item, continues: true)
        if reservedTail?.file === tail.file { reservedTail = nil }
    }

    /// Five seconds before the held-back end: crossfade into the next track if it can,
    /// otherwise schedule the end as it is and the next track gaplessly.
    func prepareTransition(from tail: ReservedTail) {
        let file = tail.file
        guard crossfadeActive, !stopsAfterCurrentTrack, let position = queue.upcoming(automatic: true),
              let device = outputDevice else {
            scheduleRest(of: tail)
            return preloadNext(after: file)
        }
        let item = queue.order[position]
        let url = queue.items[item]
        let next: TrackFile
        do {
            next = try openTrack(url, device: device)
        } catch {
            Self.log.error("[\(self.playID)] can't open next \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            scheduleRest(of: tail)
            return
        }
        guard item != tail.item, next.kind == .pcm, next.canFollow(file), shouldCrossfade?(file.url, url) ?? true else {
            scheduleRest(of: tail)
            return preloadNext(after: file)
        }

        let outgoing = file.url, start = tail.start
        let duration = crossfadeDuration, matchesBeats = crossfadeMatchesBeats
        // The incoming track's ReplayGain takes over as the fade begins; the outgoing one's
        // part of the mix keeps its own.
        let gain = Float(pow(10, (replayGainDB(for: outgoing) - replayGainDB(for: url)) / 20))
        let id = playID
        let began = ContinuousClock.now
        crossfadeTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                try? Crossfade.prepare(outgoing: outgoing, from: start, incoming: url, duration: duration,
                                       matchesBeats: matchesBeats, outgoingGain: gain)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.crossfadeTask = nil
            self.applyCrossfade(prepared, from: tail, into: next, item: item, id: id, took: ContinuousClock.now - began)
        }
    }

    private func applyCrossfade(_ prepared: Crossfade.Prepared?, from tail: ReservedTail, into next: TrackFile,
                                item: Int, id: Int, took: Duration) {
        guard reservedTail?.file === tail.file, reservedTail?.start == tail.start else { return }
        guard let prepared else {
            Self.log.debug("[\(id)] no crossfade (nothing audible to fade); joining gaplessly")
            scheduleRest(of: tail)
            return preloadNext(after: tail.file)
        }
        let plan = prepared.plan
        scheduler.append(tail.file, from: tail.start, to: plan.outStart, token: tail.item, continues: true)
        scheduler.append(prepared.buffer, standingFor: next, from: plan.inStart, token: item)
        nextReservedTail = scheduleTrack(next, from: plan.inStart + plan.length, item: item, continues: true)
        reservedTail = nil
        preloadedItem = item
        let seconds = Double(plan.length) / next.sampleRate
        Self.log.info("[\(id)] crossfade of \(String(format: "%.2f", seconds), privacy: .public) s into \(next.url.lastPathComponent, privacy: .public)\(plan.isBeatMatched ? ", on the beat" : "", privacy: .public); prepared in \(took.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// The ReplayGain applied to `url` in DSP mode, dB (the preamp included; the EQ's isn't).
    func replayGainDB(for url: URL) -> Double {
        guard replayGainMode != .off else { return 0 }
        return replayGainLookup?(url)?.gain(replayGainMode, preamp: replayGainPreamp, preventClipping: preventsClipping)
            ?? replayGainPreamp
    }
}
