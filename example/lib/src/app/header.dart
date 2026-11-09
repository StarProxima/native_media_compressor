import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 20 : 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Logo(size: compact ? 44 : 56),
                SizedBox(width: compact ? 14 : 20),
                Expanded(
                  child: Text(
                    'native_media_compressor',
                    style: (compact
                            ? theme.textTheme.titleLarge
                            : theme.textTheme.headlineMedium)
                        ?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: scheme.onPrimaryContainer,
                        ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 14 : 18),
            Text(
              'Compress video and images with the codecs your platform '
              'already ships',
              style: (compact
                      ? theme.textTheme.bodyLarge
                      : theme.textTheme.titleMedium)
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Pill(
                  icon: Icons.devices_outlined,
                  label:
                      'Running on ${_RunningPlatform.name} · '
                      '${_RunningPlatform.codecs}',
                ),
                const _Pill(icon: Icons.block, label: 'no ffmpeg'),
                const _Pill(
                  icon: Icons.inventory_2_outlined,
                  label: 'no bundled encoders',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(
        Icons.compress_rounded,
        color: scheme.onPrimary,
        size: size * 0.55,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

abstract final class _RunningPlatform {
  static String get name {
    if (kIsWeb) return 'the web';

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }

  /// The system codecs the package uses here.
  static String get codecs {
    if (kIsWeb) return 'WebCodecs';

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'MediaCodec',
      TargetPlatform.iOS || TargetPlatform.macOS => 'AVFoundation',
      TargetPlatform.windows => 'Media Foundation',
      TargetPlatform.linux => 'GStreamer',
      TargetPlatform.fuchsia => 'no codecs',
    };
  }
}
