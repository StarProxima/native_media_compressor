import Foundation

/// Lists the sound tracks of an MP4 or QuickTime file straight from its boxes.
///
/// AVFoundation leaves out tracks it cannot decode, such as MP3 inside MP4,
/// so without this such audio would be dropped silently instead of being
/// reported as unsupported.
enum ContainerAudio {
  struct Track {
    let id: Int
    let codec: String?
  }

  private static let maxMovieBoxSize: UInt64 = 64 << 20

  static func soundTracks(at url: URL) -> [Track] {
    guard let movie = readMovieBox(url) else { return [] }
    return children(of: movie, type: "trak").compactMap(soundTrack)
  }

  private static func soundTrack(_ trak: Data) -> Track? {
    guard let header = children(of: trak, type: "tkhd").first,
      let mdia = children(of: trak, type: "mdia").first,
      let hdlr = children(of: mdia, type: "hdlr").first,
      hdlr.count >= 12, fourCC(hdlr, at: 8) == "soun"
    else { return nil }
    let idOffset = header.first == 1 ? 20 : 12
    guard header.count >= idOffset + 4 else { return nil }
    let id = Int(uint32(header, at: idOffset))
    let entry = children(of: mdia, type: "minf").first
      .flatMap { children(of: $0, type: "stbl").first }
      .flatMap { children(of: $0, type: "stsd").first }
      .flatMap(firstSampleEntry)
    return Track(id: id, codec: entry.map(codec))
  }

  private static func firstSampleEntry(_ stsd: Data) -> (type: String, body: Data)? {
    // Full box header and entry count come before the first sample entry.
    let start = stsd.startIndex + 8
    guard stsd.count >= 16 else { return nil }
    let size = Int(uint32(stsd, at: 8))
    guard size >= 8, start + size <= stsd.endIndex else { return nil }
    return (fourCC(stsd, at: 12), stsd.subdata(in: (start + 8)..<(start + size)))
  }

  private static func codec(_ entry: (type: String, body: Data)) -> String {
    switch entry.type {
    case "mp4a": return objectTypeCodec(entry.body) ?? "mp4a"
    case ".mp3": return "audio/mpeg"
    case "Opus": return "audio/opus"
    case "fLaC": return "audio/flac"
    case "ac-3": return "audio/ac3"
    case "ec-3": return "audio/eac3"
    case let other: return other.trimmingCharacters(in: .whitespaces)
    }
  }

  /// Reads objectTypeIndication from the esds box, which sits directly in the
  /// sample entry in MP4 and inside a wave box in QuickTime.
  private static func objectTypeCodec(_ body: Data) -> String? {
    guard let range = body.range(of: Data("esds".utf8)) else { return nil }
    var index = range.upperBound + 4
    guard descriptor(body, tag: 0x03, at: &index) != nil, index + 3 <= body.endIndex else {
      return nil
    }
    let flags = body[index + 2]
    index += 3
    if flags & 0x80 != 0 { index += 2 }
    if flags & 0x40 != 0, index < body.endIndex { index += 1 + Int(body[index]) }
    if flags & 0x20 != 0 { index += 2 }
    guard descriptor(body, tag: 0x04, at: &index) != nil, index < body.endIndex else { return nil }
    switch body[index] {
    case 0x40, 0x66, 0x67, 0x68: return "audio/mp4a-latm"
    case 0x69, 0x6B: return "audio/mpeg"
    case 0xA5: return "audio/ac3"
    case 0xA6: return "audio/eac3"
    case 0xAD: return "audio/opus"
    default: return nil
    }
  }

  private static func descriptor(_ data: Data, tag: UInt8, at index: inout Int) -> Int? {
    guard index < data.endIndex, data[index] == tag else { return nil }
    index += 1
    var length = 0
    for _ in 0..<4 {
      guard index < data.endIndex else { return nil }
      let byte = data[index]
      index += 1
      length = length << 7 | Int(byte & 0x7F)
      if byte & 0x80 == 0 { return length }
    }
    return length
  }

  private static func readMovieBox(_ url: URL) -> Data? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { file.closeFile() }
    let fileSize = file.seekToEndOfFile()
    var offset: UInt64 = 0
    while offset + 8 <= fileSize {
      file.seek(toFileOffset: offset)
      let header = file.readData(ofLength: 16)
      guard header.count >= 8 else { return nil }
      var size = UInt64(uint32(header, at: 0))
      var headerSize: UInt64 = 8
      if size == 1 {
        guard header.count >= 16 else { return nil }
        size = UInt64(uint32(header, at: 8)) << 32 | UInt64(uint32(header, at: 12))
        headerSize = 16
      } else if size == 0 {
        size = fileSize - offset
      }
      guard size >= headerSize, offset + size <= fileSize else { return nil }
      if fourCC(header, at: 4) == "moov" {
        guard size - headerSize <= maxMovieBoxSize else { return nil }
        file.seek(toFileOffset: offset + headerSize)
        return file.readData(ofLength: Int(size - headerSize))
      }
      offset += size
    }
    return nil
  }

  private static func children(of data: Data, type: String) -> [Data] {
    var result: [Data] = []
    var index = data.startIndex
    while index + 8 <= data.endIndex {
      let size = Int(uint32(data, at: index - data.startIndex))
      guard size >= 8, index + size <= data.endIndex else { break }
      if fourCC(data, at: index - data.startIndex + 4) == type {
        result.append(data.subdata(in: (index + 8)..<(index + size)))
      }
      index += size
    }
    return result
  }

  private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    return data[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func fourCC(_ data: Data, at offset: Int) -> String {
    let start = data.startIndex + offset
    return String(bytes: data[start..<(start + 4)], encoding: .ascii) ?? ""
  }
}
