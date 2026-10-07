import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/gemini_live_service.dart';
import '../widgets/avatar_animation_widget.dart';
import 'summary_screen.dart';

/// شاشة المكالمة الكاملة:
/// 1) مرحلة الرنين (صورة المدرّب + زر إنهاء أحمر) مثل مكالمة حقيقية
/// 2) "رد تلقائي" عند اكتمال اتصال Gemini Live
/// 3) مرحلة المحادثة المباشرة (أفاتار فيديو + موجات + نص مباشر)
class LiveConversationScreen extends StatefulWidget {
  const LiveConversationScreen({super.key});

  @override
  State<LiveConversationScreen> createState() => _LiveConversationScreenState();
}

class _LiveConversationScreenState extends State<LiveConversationScreen>
    with SingleTickerProviderStateMixin {
  late GeminiLiveService _svc;
  late final AnimationController _pulse;
  Timer? _tick;
  bool _showTranscript = true;
  bool _ending = false;
  bool _declined = false; // المستخدم أنهى المكالمة أثناء الرنين

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    // تحديث المؤقت كل ثانية
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _dial();
  }

  // ---------------- بدء الاتصال أو إعادته ----------------
  void _dial() {
    _svc = GeminiLiveService();
    _svc.callState.addListener(_onCallState);
    _svc.start();
  }

  // عند الفشل نحرر الموارد ونعرض زر "Call again"
  void _onCallState() {
    if (_svc.callState.value == CallState.failed) {
      _svc.stop(playEndSound: false); // صوت الخطأ شغّال بالفعل
    }
    if (mounted) setState(() {});
  }

  void _redial() {
    _svc.callState.removeListener(_onCallState);
    setState(() => _declined = false);
    _dial();
  }

  // ---------------- إنهاء المكالمة أثناء الرنين ----------------
  Future<void> _hangUp() async {
    _svc.callState.removeListener(_onCallState);
    await _svc.stop(); // يشغّل call_end.mp3
    if (mounted) setState(() => _declined = true);
  }

  // ---------------- إنهاء المكالمة أثناء المحادثة ----------------
  Future<void> _endCall() async {
    if (_ending) return;
    _ending = true;
    _tick?.cancel();
    _svc.callState.removeListener(_onCallState);
    final dur = _svc.elapsed;
    final mistakes = _svc.mistakes.value;
    final notes = List<String>.from(_svc.takeaways);
    await _svc.stop(); // يشغّل call_end.mp3
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => SummaryScreen(
        duration: dur,
        mistakes: mistakes,
        takeaways: notes,
      ),
    ));
  }

  @override
  void dispose() {
    _pulse.dispose();
    _tick?.cancel();
    _svc.callState.removeListener(_onCallState);
    if (!_ending) _svc.stop(playEndSound: false);
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final st = _svc.callState.value;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_declined || st == CallState.failed) {
          SystemNavigator.pop(); // لا توجد مكالمة نشطة: نخرج من التطبيق
        } else if (st == CallState.connected) {
          _endCall(); // زر الرجوع ينهي المكالمة بشكل سليم
        } else {
          _hangUp();
        }
      },
      child: Scaffold(
        body: st == CallState.connected ? _liveBody() : _ringingBody(st),
      ),
    );
  }

  // =====================================================
  //                    مرحلة الرنين
  // =====================================================
  Widget _ringingBody(CallState st) {
    final failed = st == CallState.failed;
    final ringing = !failed && !_declined;
    final status = failed
        ? (_svc.errorMessage.value ?? 'فشل الاتصال، حاول مرة أخرى.')
        : _declined
            ? 'Call ended'
            : 'Calling...';

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1245), Color(0xFF0B0D17)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 28),
            const Text(
              'A-Z Live',
              style: TextStyle(
                fontSize: 16,
                letterSpacing: 2,
                color: Colors.white54,
              ),
            ),
            const Spacer(),
            _ringAvatar(ringing),
            const SizedBox(height: 28),
            const Text(
              'Coach A',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: failed ? Colors.redAccent : Colors.white70,
                ),
              ),
            ),
            const Spacer(),
            // أثناء الرنين: زر أحمر للإنهاء | بعد الفشل أو الإنهاء: زر أخضر للاتصال من جديد
            ringing
                ? _callBtn(
                    icon: Icons.call_end,
                    color: Colors.redAccent,
                    label: 'Hang up',
                    onTap: _hangUp,
                  )
                : _callBtn(
                    icon: Icons.call,
                    color: const Color(0xFF2ECC71),
                    label: 'Call again',
                    onTap: _redial,
                  ),
            const SizedBox(height: 28),
            // حقوق المبرمج بتدرج لوني متحرك
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: AnimatedGradientText(fontSize: 15),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// صورة المدرّب مع موجات نبض أثناء الرنين
  Widget _ringAvatar(bool ringing) {
    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (ringing)
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Stack(
                alignment: Alignment.center,
                children: List.generate(3, (i) {
                  final t = (_pulse.value + i / 3) % 1.0;
                  return Opacity(
                    opacity: (1 - t) * 0.5,
                    child: Container(
                      width: 160 + 120 * t,
                      height: 160 + 120 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFF7C5CFF), width: 2),
                      ),
                    ),
                  );
                }),
              ),
            ),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 3),
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/coach_avatar.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFF1A1D2E),
                  child: const Icon(Icons.person,
                      size: 80, color: Colors.white54),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _callBtn({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withAlpha(110),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  // =====================================================
  //                  مرحلة المحادثة المباشرة
  // =====================================================
  Widget _liveBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ---- الأفاتار: idle / speaking ----
        ValueListenableBuilder<AiState>(
          valueListenable: _svc.aiState,
          builder: (_, s, __) =>
              AvatarAnimationWidget(speaking: s == AiState.speaking),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xCC0B0D17),
                Colors.transparent,
                Color(0xEE0B0D17),
              ],
              stops: [0, 0.4, 1],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _topBar(),
                const SizedBox(height: 8),
                _statusChip(),
                const Spacer(),
                if (_showTranscript) _transcript(),
                const SizedBox(height: 12),
                _waves(),
                const SizedBox(height: 16),
                _controls(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- الشريط العلوي ----------------
  Widget _topBar() {
    return Row(children: [
      _Glass(
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          const Icon(Icons.circle, color: Colors.redAccent, size: 10),
          const SizedBox(width: 8),
          Text(_fmt(_svc.elapsed),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
      const SizedBox(width: 8),
      _Glass(
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: ValueListenableBuilder<int>(
          valueListenable: _svc.mistakes,
          builder: (_, m, __) => Text('✏️ $m'),
        ),
      ),
      const Spacer(),
      IconButton(
        tooltip: 'Transcript',
        onPressed: () => setState(() => _showTranscript = !_showTranscript),
        icon: Icon(
            _showTranscript ? Icons.subtitles : Icons.subtitles_off_outlined),
      ),
    ]);
  }

  // شريط يوضح من يتكلم الآن
  Widget _statusChip() {
    return ValueListenableBuilder<AiState>(
      valueListenable: _svc.aiState,
      builder: (_, s, __) => _Glass(
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Text(
          s == AiState.speaking ? 'Coach A is speaking...' : 'Listening...',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ),
    );
  }

  // ---------------- النص المباشر ----------------
  Widget _transcript() {
    return _Glass(
      child: SizedBox(
        height: 150,
        width: double.infinity,
        child: ValueListenableBuilder<List<TranscriptLine>>(
          valueListenable: _svc.transcript,
          builder: (_, lines, __) {
            final last =
                lines.length > 6 ? lines.sublist(lines.length - 6) : lines;
            return ListView(
              reverse: true,
              children: last.reversed
                  .map((l) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '${l.isUser ? "You" : "Coach"}: ${l.text}',
                          style: TextStyle(
                            color: l.isUser
                                ? const Color(0xFF22D3EE)
                                : Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ))
                  .toList(),
            );
          },
        ),
      ),
    );
  }

  // ---------------- الموجات الصوتية ----------------
  Widget _waves() {
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(children: [
        _Waveform(level: _svc.aiLevel, color: const Color(0xFF7C5CFF)),
        const Divider(height: 8, color: Colors.white12),
        _Waveform(
            level: _svc.micLevel, color: const Color(0xFF22D3EE), height: 28),
      ]),
    );
  }

  // ---------------- الأزرار ----------------
  Widget _controls() {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      // كتم الميكروفون
      ValueListenableBuilder<bool>(
        valueListenable: _svc.muted,
        builder: (_, m, __) => _roundBtn(
          icon: m ? Icons.mic_off : Icons.mic,
          color: m ? Colors.orange : Colors.white24,
          onTap: _svc.toggleMute,
        ),
      ),
      // إنهاء المكالمة
      _roundBtn(
        icon: Icons.call_end,
        color: Colors.redAccent,
        size: 72,
        onTap: _endCall,
      ),
      // اختيار اللهجة
      PopupMenuButton<Accent>(
        color: const Color(0xFF1A1D2E),
        tooltip: 'Accent',
        onSelected: _svc.setAccent,
        itemBuilder: (_) => Accent.values
            .map((a) => PopupMenuItem(
                  value: a,
                  child: Row(children: [
                    Text(a.label),
                    if (a == _svc.accent.value) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check, size: 16),
                    ],
                  ]),
                ))
            .toList(),
        child: _roundBtn(icon: Icons.record_voice_over, color: Colors.white24),
      ),
    ]);
  }

  Widget _roundBtn({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    double size = 58,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        child: Icon(icon, color: Colors.white, size: size * 0.45),
      ),
    );
  }
}

// =============== حاوية زجاجية (Glassmorphism) ===============
class _Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  const _Glass({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(22),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withAlpha(40)),
          ),
          child: child,
        ),
      ),
    );
  }
}

// =============== موجة صوتية حية (0..1) ===============
class _Waveform extends StatefulWidget {
  final ValueListenable<double> level;
  final Color color;
  final double height;
  const _Waveform({
    required this.level,
    required this.color,
    this.height = 40,
  });

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform> {
  static const _bars = 32;
  final List<double> _hist = List.filled(_bars, 0.02);

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(covariant _Waveform old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
  }

  void _onLevel() {
    if (!mounted) return;
    setState(() {
      _hist.removeAt(0);
      _hist.add(widget.level.value.clamp(0.02, 1.0));
    });
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(painter: _WavePainter(List.of(_hist), widget.color)),
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> h;
  final Color c;
  _WavePainter(this.h, this.c);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width / h.length;
    final p = Paint()
      ..color = c
      ..strokeCap = StrokeCap.round
      ..strokeWidth = w * 0.55;
    for (var i = 0; i < h.length; i++) {
      final bar = h[i] * s.height;
      final x = i * w + w / 2;
      canvas.drawLine(Offset(x, s.height / 2 - bar / 2),
          Offset(x, s.height / 2 + bar / 2), p);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

// =============== نص حقوق المبرمج بتدرج لوني متحرك ===============
class AnimatedGradientText extends StatefulWidget {
  final double fontSize;
  const AnimatedGradientText({super.key, this.fontSize = 14});

  @override
  State<AnimatedGradientText> createState() => _AnimatedGradientTextState();
}

class _AnimatedGradientTextState extends State<AnimatedGradientText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: const [
                Color(0xFF7C5CFF),
                Color(0xFF22D3EE),
                Color(0xFF2ECC71),
              ],
              stops: [
                0.0,
                _controller.value,
                1.0,
              ],
            ).createShader(bounds);
          },
          child: Text(
            'جميع الحقوق محفوظة لدى المبرمج عزام عدنان المخلافي',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }
}
