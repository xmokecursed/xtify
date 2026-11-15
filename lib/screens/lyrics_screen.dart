import 'package:flutter/material.dart';
import '../desktop/desktop_scope.dart';
import '../widgets/lyrics_controller.dart';
import '../widgets/lyrics_section.dart';
import '../widgets/player_sheet.dart';

class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  final LyricsController _controller = LyricsController(follow: true);

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = kToolbarHeight + media.padding.top;
    final bottom = DesktopScope.isWide(context) ? 0.0 : media.size.height * 0.11 + 8;
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final tint = _controller.tint;
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _controller.title.isEmpty ? 'Lyrics' : _controller.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                if (_controller.artist.isNotEmpty)
                  Text(
                    _controller.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: Colors.white70),
                  ),
              ],
            ),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 700),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [tint, Color.lerp(tint, Colors.black, 0.82)!],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: top, bottom: bottom),
                  child: LyricsBody(controller: _controller),
                ),
              ),
              const PlayerSheet(),
            ],
          ),
        );
      },
    );
  }
}
