/// Human-readable numbers for sizes, bitrates and durations.
abstract final class Formats {
  static const _kb = 1024;
  static const _mb = 1024 * 1024;
  static const _gb = 1024 * 1024 * 1024;

  static String bytes(int bytes) {
    if (bytes < _kb) return '$bytes B';
    if (bytes < _mb) return '${(bytes / _kb).round()} KB';
    if (bytes < _gb) return '${_short(bytes / _mb)} MB';

    return '${(bytes / _gb).toStringAsFixed(2)} GB';
  }

  static String resolution(int width, int height) => '$width×$height';

  static String bitrate(int bitsPerSecond) =>
      bitsPerSecond >= 1000000
          ? '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbit/s'
          : '${(bitsPerSecond / 1000).round()} kbit/s';

  /// `0:05`, `12:34` or `1:02:03`.
  static String duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
  }

  /// Like [duration], with tenths of a second for trim handles.
  static String position(Duration position) {
    final tenths = position.inMilliseconds.remainder(1000) ~/ 100;

    return '${duration(position)}.$tenths';
  }

  /// `0.8 s`, `14 s` or `2 min 05 s`.
  static String elapsed(Duration elapsed) {
    final seconds = elapsed.inMilliseconds / 1000;
    if (seconds < 10) return '${seconds.toStringAsFixed(1)} s';
    if (seconds < 60) return '${seconds.round()} s';
    final rest = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');

    return '${elapsed.inMinutes} min $rest s';
  }

  /// `-88%` when [after] is smaller than [before], `+3%` when it grew.
  static String change(int before, int after) {
    if (before <= 0) return '';
    final percent = ((after - before) * 100 / before).round();

    return percent > 0 ? '+$percent%' : '$percent%';
  }

  /// A short name for a codec or image MIME type.
  static String codec(String? mimeType) => switch (mimeType) {
    null => 'Unknown',
    'video/avc' => 'H.264',
    'video/hevc' => 'HEVC',
    'video/x-vnd.on2.vp8' || 'video/vp8' => 'VP8',
    'video/x-vnd.on2.vp9' || 'video/vp9' => 'VP9',
    'video/av01' || 'video/av1' => 'AV1',
    'audio/mp4a-latm' || 'audio/aac' => 'AAC',
    'audio/mpeg' => 'MP3',
    'audio/opus' => 'Opus',
    'image/jpeg' => 'JPEG',
    'image/png' => 'PNG',
    'image/heic' || 'image/heif' => 'HEIC',
    'image/webp' => 'WebP',
    'image/gif' => 'GIF',
    _ => mimeType.split('/').last.toUpperCase(),
  };

  static String _short(double value) =>
      value.toStringAsFixed(value < 10 ? 2 : (value < 100 ? 1 : 0));
}
