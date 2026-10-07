import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// يبدّل بين فيديو idle وفيديو speaking بسلاسة (Cross-fade)
/// - idle يعمل دائماً في حلقة
/// - speaking يبدأ من الصفر لحظة speaking=true ويتوقف فوراً عند false
class AvatarAnimationWidget extends StatefulWidget {
  final bool speaking;
  const AvatarAnimationWidget({super.key, required this.speaking});

  @override
  State<AvatarAnimationWidget> createState() => _AvatarAnimationWidgetState();
}

class _AvatarAnimationWidgetState extends State<AvatarAnimationWidget> {
  late final VideoPlayerController _idle;
  late final VideoPlayerController _talk;
  bool _ok = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _idle = VideoPlayerController.asset(
      'assets/videos/idle_avatar.mp4',
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _talk = VideoPlayerController.asset(
      'assets/videos/speaking_avatar.mp4',
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _init();
  }

  Future<void> _init() async {
    try {
      await Future.wait([_idle.initialize(), _talk.initialize()]);
      for (final c in [_idle, _talk]) {
        await c.setLooping(true);
        await c.setVolume(0); // الصوت يأتي من Gemini وليس من الفيديو
      }
      await _idle.play();
      if (widget.speaking) await _talk.play();
      if (mounted) setState(() => _ok = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didUpdateWidget(covariant AvatarAnimationWidget old) {
    super.didUpdateWidget(old);
    if (!_ok || old.speaking == widget.speaking) return;
    if (widget.speaking) {
      _talk.seekTo(Duration.zero).then((_) => _talk.play());
    } else {
      _talk.pause();
    }
  }

  @override
  void dispose() {
    _idle.dispose();
    _talk.dispose();
    super.dispose();
  }

  Widget _video(VideoPlayerController c) => FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      // بديل بسيط في حال تعذّر تشغيل الفيديو
      return Center(
        child: AnimatedScale(
          scale: widget.speaking ? 1.15 : 1.0,
          duration: const Duration(milliseconds: 300),
          child: const Icon(Icons.record_voice_over,
              size: 120, color: Colors.white38),
        ),
      );
    }
    if (!_ok) return const Center(child: CircularProgressIndicator());

    return Stack(
      fit: StackFit.expand,
      children: [
        _video(_idle),
        AnimatedOpacity(
          opacity: widget.speaking ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: _video(_talk),
        ),
      ],
    );
  }
}
