import 'package:flutter/material.dart';

import '../image/image_workspace.dart';
import '../media/picked_media.dart';
import '../video/video_workspace.dart';
import 'footer.dart';
import 'header.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  var _kind = MediaKind.video;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final gutter = width < 600 ? 16.0 : 32.0;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(gutter, gutter, gutter, 8),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AppHeader(),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _KindSwitcher(
                      value: _kind,
                      onChanged: (kind) => setState(() => _kind = kind),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Both stay mounted so switching tabs keeps each one's
                  // source, settings and result.
                  Visibility(
                    visible: _kind == MediaKind.video,
                    maintainState: true,
                    child: const VideoWorkspace(),
                  ),
                  Visibility(
                    visible: _kind == MediaKind.image,
                    maintainState: true,
                    child: const ImageWorkspace(),
                  ),
                  const SizedBox(height: 32),
                  const AppFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KindSwitcher extends StatelessWidget {
  const _KindSwitcher({required this.value, required this.onChanged});

  final MediaKind value;
  final ValueChanged<MediaKind> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<MediaKind>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.standard,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 24)),
      ),
      segments: const [
        ButtonSegment(
          value: MediaKind.video,
          icon: Icon(Icons.movie_outlined),
          label: Text('Video'),
        ),
        ButtonSegment(
          value: MediaKind.image,
          icon: Icon(Icons.image_outlined),
          label: Text('Image'),
        ),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.single),
    );
  }
}
