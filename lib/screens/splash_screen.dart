import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'live_conversation_screen.dart';

/// شاشة البداية: تشغّل splash_intro.mp4 ثم تنتقل تلقائياً إلى LiveConversationScreen
/// حماية: انتقال واحد فقط، مؤقت احتياطي، تخطي بالضغط، وبديل عند تعذّر الفيديو
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late final VideoPlayerController _c;
  Timer? _failsafe;
  bool _ready = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.asset('assets/videos/splash_intro.mp4');
    _init();
  }

  Future<void> _init() async {
    try {
      await _c.initialize();
      if (!mounted) return;
      await _c.setLooping(false);
      await _c.setVolume(1);
      _c.addListener(_onTick);
      setState(() => _ready = true);
      await _c.play();
      // مؤقت احتياطي لو لم يصل مستمع النهاية لأي سبب
      _failsafe = Timer(
        _c.value.duration + const Duration(seconds: 1),
        _goNext,
      );
    } catch (_) {
      // تعذّر تشغيل الفيديو: ننتظر ثانيتين ثم نكمل
      _failsafe = Timer(const Duration(seconds: 2), _goNext);
    }
  }

  void _onTick() {
    final v = _c.value;
    if (v.hasError) {
      _goNext();
      return;
    }
    if (v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 80)) {
      _goNext();
    }
  }

  void _goNext() {
    if (_navigated || !mounted) return;
    _navigated = true;
    _failsafe?.cancel();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LiveConversationScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  void dispose() {
    _failsafe?.cancel();
    _c.removeListener(_onTick);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _goNext, // اضغط لتخطي الفيديو
        child: _ready
            ? SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _c.value.size.width,
                    height: _c.value.size.height,
                    child: VideoPlayer(_c),
                  ),
                ),
              )
            : const Center(
                child: Text(
                  'A-Z Live',
                  style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
                ),
              ),
      ),
    );
  }
}
