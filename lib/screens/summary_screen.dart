import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'live_conversation_screen.dart';

/// نص حقوق المبرمج بخط واضح وتدرج لوني متحرك باستمرار
/// يُستخدم في شاشة الملخص وشاشة الرنين
class AnimatedGradientText extends StatefulWidget {
  final String text;
  final double fontSize;

  const AnimatedGradientText({
    super.key,
    this.text = 'جميع الحقوق محفوظة لدى المبرمج عزام عدنان المخلافي',
    this.fontSize = 14,
  });

  @override
  State<AnimatedGradientText> createState() => _AnimatedGradientTextState();
}

class _AnimatedGradientTextState extends State<AnimatedGradientText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  // اللون الأول مكرر في النهاية ليكون التكرار سلساً بدون قفزة
  static const _colors = <Color>[
    Color(0xFF22D3EE),
    Color(0xFF7C5CFF),
    Color(0xFFFF4DA6),
    Color(0xFFFFB020),
    Color(0xFF2ECC71),
    Color(0xFF22D3EE),
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 5))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(110), // خلفية داكنة لتوضيح القراءة
        borderRadius: BorderRadius.circular(16),
      ),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            colors: _colors,
            tileMode: TileMode.repeated,
            transform: _SlideGradient(_c.value),
          ).createShader(rect),
          child: Text(
            widget.text,
            textAlign: TextAlign.center,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              height: 1.5,
              color: Colors.white, // يُستبدل لونه بالتدرج
            ),
          ),
        ),
      ),
    );
  }
}

/// يزحزح التدرج أفقياً مع الزمن فيبدو اللون وكأنه يجري داخل الحروف
class _SlideGradient extends GradientTransform {
  final double t;
  const _SlideGradient(this.t);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(-bounds.width * t, 0, 0);
  }
}

/// حفظ سلسلة الأيام المتتالية محلياً
class ProgressStore {
  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// تُستدعى عند انتهاء المكالمة؛ تعيد عدد الأيام المتتالية الحالي
  static Future<int> registerSession() async {
    final p = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));
    final last = p.getString('last_day');
    var streak = p.getInt('streak') ?? 0;

    if (last == _fmt(today)) {
      if (streak == 0) streak = 1; // نفس اليوم: لا زيادة
    } else if (last == _fmt(yesterday)) {
      streak += 1; // يوم متتالٍ
    } else {
      streak = 1; // انقطعت السلسلة
    }
    await p.setString('last_day', _fmt(today));
    await p.setInt('streak', streak);
    return streak;
  }
}

/// ملخص ما بعد المكالمة: المدة، الأخطاء، الملاحظات، السلسلة، وحقوق المبرمج
class SummaryScreen extends StatefulWidget {
  final Duration duration;
  final int mistakes;
  final List<String> takeaways;

  const SummaryScreen({
    super.key,
    required this.duration,
    required this.mistakes,
    required this.takeaways,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late final Future<int> _streak;

  @override
  void initState() {
    super.initState();
    _streak = ProgressStore.registerSession(); // مرة واحدة فقط
  }

  String get _dur =>
      '${widget.duration.inMinutes}m ${(widget.duration.inSeconds % 60).toString().padLeft(2, '0')}s';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1B1245), Color(0xFF0B0D17)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('Call Summary 🎉',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: _stat(Icons.timer_outlined, 'المدة', _dur)),
                const SizedBox(width: 12),
                Expanded(
                    child: _stat(Icons.edit_note, 'أخطاء مصححة',
                        '${widget.mistakes}')),
              ]),
              const SizedBox(height: 12),
              FutureBuilder<int>(
                future: _streak,
                builder: (_, snap) => _streakCard(snap.data ?? 0),
              ),
              const SizedBox(height: 12),
              _glass(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('أهم الملاحظات',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    if (widget.takeaways.isEmpty)
                      const Text('لا أخطاء مسجلة، أحسنت! 👏',
                          style: TextStyle(color: Colors.white70))
                    else
                      ...widget.takeaways.map((t) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('• ',
                                    style:
                                        TextStyle(color: Color(0xFF22D3EE))),
                                Expanded(child: Text(t)),
                              ],
                            ),
                          )),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                      builder: (_) => const LiveConversationScreen()),
                ),
                icon: const Icon(Icons.call),
                label: const Text('ابدأ مكالمة جديدة'),
              ),
              const SizedBox(height: 28),
              // حقوق المبرمج
              const Center(child: AnimatedGradientText(fontSize: 14)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _glass(Widget child) => ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(22),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withAlpha(40)),
            ),
            child: child,
          ),
        ),
      );

  Widget _stat(IconData i, String label, String value) => _glass(
        Column(children: [
          Icon(i, color: const Color(0xFF22D3EE)),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ]),
      );

  Widget _streakCard(int streak) {
    const days = ['س', 'ح', 'ن', 'ث', 'ر', 'خ', 'ج'];
    final lit = streak.clamp(0, 7);
    return _glass(
      Column(children: [
        Text('🔥 سلسلة $streak ${streak == 1 ? "يوم" : "أيام"} متتالية',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(7, (i) {
            final on = i < lit;
            return CircleAvatar(
              radius: 18,
              backgroundColor:
                  on ? Colors.orangeAccent : Colors.white.withAlpha(25),
              child: Text(days[i],
                  style: TextStyle(
                      color: on ? Colors.black : Colors.white54,
                      fontWeight: FontWeight.bold)),
            );
          }),
        ),
      ]),
    );
  }
}
