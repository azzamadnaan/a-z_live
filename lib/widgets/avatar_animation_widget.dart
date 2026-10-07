import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// ويدجت عرض فيديو الأفاتار بدون تقطيع أو تذبذب
class AvatarAnimationWidget extends StatefulWidget {
  final bool speaking;

  const AvatarAnimationWidget({
    super.key,
    required this.speaking,
  });

  @override
  State<AvatarAnimationWidget> createState() => _AvatarAnimationWidgetState();
}

class _AvatarAnimationWidgetState extends State<AvatarAnimationWidget> {
  late VideoPlayerController _idleController;
  late VideoPlayerController _speakingController;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initVideoControllers();
  }

  /// تحميل الفيديويين مسبقاً في الذاكرة لمنع أي ومضات أثناء التبديل
  Future<void> _initVideoControllers() async {
    _idleController =
        VideoPlayerController.asset('assets/videos/idle_avatar.mp4');
    _speakingController =
        VideoPlayerController.asset('assets/videos/speaking_avatar.mp4');

    try {
      await Future.wait([
        _idleController.initialize(),
        _speakingController.initialize(),
      ]);

      _idleController.setLooping(true);
      _speakingController.setLooping(true);

      _idleController.play();
      _speakingController.play();

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint("خطأ في تحميل الفيديوهات: $e");
    }
  }

  @override
  void didUpdateWidget(AvatarAnimationWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // عند تغير الحالة فقط
    if (oldWidget.speaking != widget.speaking && _isInitialized) {
      if (widget.speaking) {
        _speakingController.seekTo(Duration.zero);
        _speakingController.play();
      } else {
        _idleController.play();
      }
    }
  }

  @override
  void dispose() {
    _idleController.dispose();
    _speakingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Container(
        color: const Color(0xFF0B0D17),
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFF7C5CFF)),
        ),
      );
    }

    // التبديل الفوري عبر IndexedStack يمنع إعادة بناء الشاشة أو حدوث ومضات سوداء
    return IndexedStack(
      index: widget.speaking ? 1 : 0,
      children: [
        // فيديو الاستماع/الانتظار (Idle)
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _idleController.value.size.width > 0
                  ? _idleController.value.size.width
                  : 1080,
              height: _idleController.value.size.height > 0
                  ? _idleController.value.size.height
                  : 1920,
              child: VideoPlayer(_idleController),
            ),
          ),
        ),
        // فيديو الكلام (Speaking)
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _speakingController.value.size.width > 0
                  ? _speakingController.value.size.width
                  : 1080,
              height: _speakingController.value.size.height > 0
                  ? _speakingController.value.size.height
                  : 1920,
              child: VideoPlayer(_speakingController),
            ),
          ),
        ),
      ],
    );
  }
}
