import Foundation

/// The audio a player would play, and so the audio to keep.
///
/// Tracks of one alternate group are alternatives of each other: iPhone
/// spatial audio stores APAC with a stereo AAC fallback in one group. One
/// track per group is kept, AAC first because it is copied without
/// re-encoding, and a group with no enabled track is never played, so it is
/// skipped.
struct AudioPlan {
  enum Source {
    /// AAC, copied as is.
    case copy(MediaAsset.AudioTrack)
    /// Another codec AVFoundation decodes, re-encoded to AAC.
    case encode(MediaAsset.AudioTrack)
    /// MPEG audio that AVFoundation hides inside MP4, re-encoded to AAC from
    /// frames read out of the container.
    case encodeHidden(ContainerAudio.Track)
  }

  /// One source per played group.
  var sources: [Source] = []
  /// Codec of the first played group that has nothing this platform decodes.
  var unreadableCodec: String?
  var hasUnreadable = false
  /// Codec of the first played track, for the probe.
  var firstCodec: String?
}

extension MediaAsset {
  var audioPlan: AudioPlan {
    struct Candidate {
      let group: String
      let isEnabled: Bool
      let codec: String?
      let source: AudioPlan.Source?
      let rank: Int
    }
    let candidates =
      audio.map {
        Candidate(
          group: groupKey(of: $0.id), isEnabled: $0.isEnabled, codec: $0.codec,
          source: $0.isAAC ? .copy($0) : .encode($0), rank: $0.isAAC ? 0 : 1)
      }
      + unreadableAudio.map {
        let isMPEG = $0.codec == "audio/mpeg"
        return Candidate(
          group: groupKey(of: $0.id), isEnabled: $0.isEnabled, codec: $0.codec,
          source: isMPEG ? .encodeHidden($0) : nil, rank: 2)
      }

    var plan = AudioPlan()
    var seen = Set<String>()
    for group in candidates.map(\.group) where seen.insert(group).inserted {
      let members = candidates.filter { $0.group == group }
      guard let played = members.first(where: \.isEnabled) else { continue }
      if plan.firstCodec == nil { plan.firstCodec = played.codec }
      let usable = members.filter { $0.source != nil }
      let best = usable.min {
        ($0.rank, $0.isEnabled ? 0 : 1) < ($1.rank, $1.isEnabled ? 0 : 1)
      }
      if let source = best?.source {
        plan.sources.append(source)
      } else if !plan.hasUnreadable {
        plan.hasUnreadable = true
        plan.unreadableCodec = played.codec
      }
    }
    return plan
  }

  /// The container's own alternate group is preferred because it also covers
  /// tracks AVFoundation hides; AVFoundation's groups are the fallback.
  private func groupKey(of id: Int) -> String {
    if let track = containerAudio.first(where: { $0.id == id }) {
      return track.alternateGroup == 0 ? "track \(id)" : "group \(track.alternateGroup)"
    }
    if let index = alternateGroups.firstIndex(where: { $0.contains(id) }) {
      return "avf group \(index)"
    }
    return "track \(id)"
  }
}
