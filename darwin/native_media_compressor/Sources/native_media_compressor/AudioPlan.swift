import Foundation

/// The audio a player would play, and so the audio to copy.
///
/// Tracks of one alternate group are alternatives of each other: iPhone
/// spatial audio stores APAC with a stereo AAC fallback in one group. One
/// track per group is copied, AAC first, and a group with no enabled track is
/// never played, so it is skipped.
struct AudioPlan {
  /// AAC tracks to copy, one per played group.
  var tracks: [MediaAsset.AudioTrack] = []
  /// Codec of the first played group that has no AAC track to copy.
  var uncopyableCodec: String?
  var hasUncopyable = false
  /// Codec of the first played track, for the probe.
  var firstCodec: String?
}

extension MediaAsset {
  var audioPlan: AudioPlan {
    struct Candidate {
      let group: String
      let isEnabled: Bool
      let codec: String?
      let aac: AudioTrack?
    }
    let candidates =
      audio.map {
        Candidate(group: groupKey(of: $0.id), isEnabled: $0.isEnabled, codec: $0.codec, aac: $0.isAAC ? $0 : nil)
      }
      + unreadableAudio.map {
        Candidate(group: groupKey(of: $0.id), isEnabled: $0.isEnabled, codec: $0.codec, aac: nil)
      }

    var plan = AudioPlan()
    var seen = Set<String>()
    for group in candidates.map(\.group) where seen.insert(group).inserted {
      let members = candidates.filter { $0.group == group }
      guard let played = members.first(where: \.isEnabled) else { continue }
      if plan.firstCodec == nil { plan.firstCodec = played.codec }
      let copyable = members.filter { $0.aac != nil }
      if let aac = (copyable.first(where: \.isEnabled) ?? copyable.first)?.aac {
        plan.tracks.append(aac)
      } else if !plan.hasUncopyable {
        plan.hasUncopyable = true
        plan.uncopyableCodec = played.codec
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
