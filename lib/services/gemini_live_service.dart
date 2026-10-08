import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum Accent { american, british, australian }

enum AiState { idle, speaking }

enum CallState { connecting, connected, failed }

class TranscriptLine {
  final bool isUser;
  String text;
  TranscriptLine(this.isUser, this.text);
}

extension AccentX on Accent {
  String get label => switch (this) {
        Accent.american => 'American 🇺🇸',
        Accent.british => 'British 🇬🇧',
        Accent.australian => 'Australian 🇦🇺',
      };
  String get prompt => switch (this) {
        Accent.american => 'American English',
        Accent.british => 'British English (Received Pronunciation)',
        Accent.australian => 'Australian English',
      };
}

/// مشغّل المؤثرات الصوتية
class SfxPlayer {
  final AudioPlayer _ring = AudioPlayer();
  final AudioPlayer _fx = AudioPlayer();

  Future<void> init() async {
    try {
      final ctx = AudioContext(
        android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.defaultToSpeaker,
          },
        ),
      );
      await _ring.setAudioContext(ctx);
      await _fx.setAudioContext(ctx);
      await _ring.setReleaseMode(ReleaseMode.loop);
    } catch (e) {
      debugPrint('SFX init error: $e');
    }
  }

  Future<void> startRing() async {
    try {
      await _ring.play(AssetSource('audio/calling_ring.mp3'));
    } catch (e) {
      debugPrint('ring error: $e');
    }
  }

  Future<void> stopRing() async {
    try {
      await _ring.stop();
    } catch (_) {}
  }

  Future<void> play(String file) async {
    try {
      await _fx.stop();
      await _fx.play(AssetSource('audio/$file'));
    } catch (e) {
      debugPrint('sfx error ($file): $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _ring.dispose();
      await _fx.dispose();
    } catch (_) {}
  }
}

/// خدمة الاتصال المباشر مع Gemini Live API
class GeminiLiveService {
  static const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

  static const String _model =
      'models/gemini-2.5-flash-native-audio-preview-09-2025';
  static const String _wsUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  static const bool stayInSpeakingUntilClearSpeech = true;
  static const Duration _minRing = Duration(seconds: 3);
  static const Duration _maxOffline = Duration(seconds: 30);
  static const List<int> _backoffSeconds = [1, 2, 4, 8];

  static const Set<String> _fillers = {
    'uh', 'um', 'umm', 'hmm', 'hm', 'ah', 'er', 'eh', 'mm', 'oh', 'huh', 'aa',
  };

  // ---- حالات قابلة للمراقبة من الواجهة ----
  final callState = ValueNotifier<CallState>(CallState.connecting);
  final errorMessage = ValueNotifier<String?>(null);
  final aiState = ValueNotifier<AiState>(AiState.idle);
  final reconnecting = ValueNotifier<bool>(false);
  final micLevel = ValueNotifier<double>(0);
  final aiLevel = ValueNotifier<double>(0);
  final transcript = ValueNotifier<List<TranscriptLine>>([]);
  final mistakes = ValueNotifier<int>(0);
  final accent = ValueNotifier<Accent>(Accent.american);
  final muted = ValueNotifier<bool>(false);
  final takeaways = <String>[];

  final _sfx = SfxPlayer();
  final _rec = AudioRecorder();
  final _lines = <TranscriptLine>[];

  WebSocketChannel? _ch;
  StreamSubscription? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _setupTimeout;
  Timer? _endSpeakTimer;
  Timer? _reconnectTimer;

  bool _ready = false;
  bool _firstConnectDone = false;
  bool _pcmReady = false;
  bool _disposed = false;
  bool _dropAudio = false;
  bool _turnCounted = false;
  String _turnText = '';
  String _userText = '';
  String? _resumeText;
  int _loudChunks = 0;
  int _attempt = 0;
  DateTime _playUntil = DateTime.now();
  DateTime? _ringStart;
  DateTime? _offlineSince;
  DateTime? startedAt;

  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  bool get _isPlaying => _playUntil.isAfter(DateTime.now());

  // ================= بدء الجلسة =================
  Future<void> start() async {
    callState.value = CallState.connecting;
    _ringStart = DateTime.now();
    await _sfx.init();
    _sfx.startRing();
    try {
      if (_apiKey.isEmpty) {
        throw Exception(
            'مفتاح GEMINI_API_KEY غير موجود. تأكد من إضافته في GitHub Secrets أو --dart-define.');
      }
      if (!await _rec.hasPermission()) {
        throw Exception('صلاحية الميكروفون مرفوضة. فعّلها من إعدادات الهاتف.');
      }
      await _connect();
      await _startMic();
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fail(String msg) {
    if (_disposed || callState.value == CallState.failed) return;
    _setupTimeout?.cancel();
    _reconnectTimer?.cancel();
    reconnecting.value = false;
    _sfx.stopRing();
    _sfx.play('error_alert.mp3');
    errorMessage.value = msg;
    callState.value = CallState.failed;
  }

  // ================= شخصية المدرّب =================
  String _systemPrompt() => '''
You are "Coach A", an engaging, slightly strict English tutor in the app A-Z Live.
Speak ONLY in ${accent.value.prompt}. Keep replies short (1-3 sentences) and always end with a question to keep the learner talking.
Listen carefully to the learner's grammar and pronunciation.
When the learner's speech is unclear, broken, or badly pronounced, do NOT ignore it. First say what you understood in a friendly way, answer it briefly, then give the correct sentence, then ask the learner to repeat it.
Example: if the learner says "hoo yoo ar", reply: "I think you said: how are you? I'm fine, thank you! You can say it like this: How are you? Please correct that and try again."
Always begin the correction with "You are half wrong!" or "Almost! Here is how a native says it:".
If you cannot understand anything at all, say: "Sorry, I could not understand. Please say it again slowly."
If they are correct, praise briefly and continue the conversation.
Start by greeting the learner and asking an easy question.''';

  // ================= الاتصال بالخادم =================
  Future<void> _connect() async {
    _ready = false;
    _ch = WebSocketChannel.connect(Uri.parse('$_wsUrl?key=$_apiKey'));
    await _ch!.ready;

    _wsSub = _ch!.stream.listen(
      _onMessage,
      onError: (e) => _onWsLost('خطأ في الاتصال: $e'),
      onDone: () => _onWsLost('انقطع الاتصال بالخادم.'),
    );

    _setupTimeout?.cancel();
    _setupTimeout = Timer(const Duration(seconds: 15), () {
      if (_ready || _disposed) return;
      if (callState.value == CallState.connected) {
        _scheduleReconnect();
      } else {
        _fail('انتهت مهلة الاتصال. حاول مرة أخرى.');
      }
    });

    _send({
      'setup': {
        'model': _model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Puck'}
            }
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': _systemPrompt()}
          ]
        },
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
      }
    });
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _onWsLost(String msg) {
    if (_disposed) return;
    if (callState.value == CallState.connected) {
      _handleDisconnect();
    } else {
      _fail(msg);
    }
  }

  void _handleDisconnect() {
    if (_disposed || callState.value != CallState.connected) return;
    _ready = false;
    _resumeText = _buildResumeText(connectionLost: true);
    reconnecting.value = true;
    _offlineSince ??= DateTime.now();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectTimer?.isActive ?? false) return;

    final since = _offlineSince ??= DateTime.now();
    reconnecting.value = true;

    if (DateTime.now().difference(since) > _maxOffline) {
      _fail('انقطع الإنترنت لأكثر من 30 ثانية. تأكد من الاتصال ثم أعد الاتصال.');
      return;
    }

    final delay = _backoffSeconds[math.min(_attempt, _backoffSeconds.length - 1)];
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: delay), _tryReconnect);
  }

  Future<void> _tryReconnect() async {
    if (_disposed || callState.value != CallState.connected) return;
    try {
      await _wsSub?.cancel();
      try {
        await _ch?.sink.close();
      } catch (_) {}
      await _connect();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  String _buildResumeText({required bool connectionLost}) {
    final last = _lines.length > 4 ? _lines.sublist(_lines.length - 4) : _lines;
    final recent = last
        .map((l) => '${l.isUser ? "Learner" : "Coach"}: ${l.text}')
        .join(' | ');
    final head = connectionLost
        ? 'The connection was interrupted for a moment.'
        : 'Please switch to your new accent (${accent.value.prompt}).';
    final ctx = recent.isEmpty ? '' : ' Recent conversation: $recent.';
    return '$head$ctx Continue the lesson naturally and do not greet me again.';
  }

  // ================= الرد التلقائي بعد اكتمال الاتصال =================
  Future<void> _handleSetupComplete() async {
    final firstTime = !_firstConnectDone;
    if (firstTime) {
      final waited = DateTime.now().difference(_ringStart ?? DateTime.now());
      if (waited < _minRing) await Future.delayed(_minRing - waited);
    }
    if (_disposed || callState.value == CallState.failed) return;

    _ready = true;
    _firstConnectDone = true;
    _dropAudio = false;

    if (firstTime) {
      _sfx.stopRing();
      _sfx.play('connected.mp3');
      startedAt = DateTime.now();
      callState.value = CallState.connected;
      _send({
        'realtimeInput': {'text': 'Hi coach, please start the lesson.'}
      });
    } else {
      _offlineSince = null;
      _attempt = 0;
      _reconnectTimer?.cancel();
      reconnecting.value = false;
      _send({
        'realtimeInput': {
          'text': _resumeText ??
              'Please continue our conversation naturally and do not greet me again.'
        }
      });
      _resumeText = null;
    }
  }

  // ================= الميكروفون =================
  Future<void> _startMic() async {
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    ));

    _micSub = stream.listen((chunk) {
      final level = _rms(chunk);
      micLevel.value = muted.value ? 0 : level;

      if (_isPlaying && !muted.value) {
        _loudChunks = level > 0.12 ? _loudChunks + 1 : 0;
        if (_loudChunks >= 2) {
          _loudChunks = 0;
          interrupt();
        }
      }

      if (_ready && !muted.value) {
        _send({
          'realtimeInput': {
            'audio': {
              'data': base64Encode(chunk),
              'mimeType': 'audio/pcm;rate=16000',
            }
          }
        });
      }
    });
  }

  double _rms(Uint8List b) {
    final n = b.lengthInBytes ~/ 2;
    if (n == 0) return 0;
    final d = ByteData.sublistView(b);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final s = d.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.min(1.0, math.sqrt(sum / n) * 4);
  }

  // ================= الكلام الواضح =================
  bool _isClearSpeech(String text) {
    final words = RegExp(r"[A-Za-z']+")
        .allMatches(text)
        .map((m) => m.group(0)!.toLowerCase())
        .where((w) => !_fillers.contains(w))
        .toList();
    if (words.length < 2) return false;
    final letters = words.join().replaceAll("'", '');
    if (letters.length < 4) return false;
    if (letters.split('').toSet().length < 3) return false;
    return true;
  }

  void _checkClearSpeech() {
    if (!stayInSpeakingUntilClearSpeech) return;
    if (aiState.value != AiState.speaking) return;
    if (_isPlaying) return;
    if (_isClearSpeech(_userText)) _goIdle();
  }

  // ================= استقبال الرسائل =================
  void _onMessage(dynamic data) {
    if (_disposed) return;
    final String text;
    try {
      text = data is String ? data : utf8.decode(data as List<int>);
    } catch (_) {
      return;
    }
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg.containsKey('setupComplete')) {
      _setupTimeout?.cancel();
      _handleSetupComplete();
      return;
    }

    final sc = msg['serverContent'] as Map<String, dynamic>?;
    if (sc == null) return;

    if (sc['interrupted'] == true) {
      _handleServerInterrupted();
    }

    final parts = (sc['modelTurn']?['parts'] as List?) ?? const [];
    for (final p in parts) {
      final inline = p['inlineData'];
      if (inline != null && inline['data'] != null && !_dropAudio) {
        _playChunk(base64Decode(inline['data'] as String));
      }
    }

    final inT = sc['inputTranscription']?['text'] as String?;
    if (inT != null && inT.isNotEmpty) {
      _appendLine(true, inT);
      _userText += inT;
      _checkClearSpeech();
    }

    final outT = sc['outputTranscription']?['text'] as String?;
    if (outT != null && outT.isNotEmpty && !_dropAudio) {
      _appendLine(false, outT);
      _turnText += outT;
      if (!_turnCounted &&
          RegExp(r'half wrong|almost!', caseSensitive: false)
              .hasMatch(_turnText)) {
        _turnCounted = true;
        mistakes.value += 1;
      }
    }

    if (sc['turnComplete'] == true) {
      _dropAudio = false;
      if (_turnCounted && _turnText.trim().isNotEmpty) {
        takeaways.add(_turnText.trim());
      }
      _turnCounted = false;
      _turnText = '';
      _userText = '';
    }
  }

  void _appendLine(bool isUser, String t) {
    if (_lines.isNotEmpty && _lines.last.isUser == isUser) {
      _lines.last.text += t;
    } else {
      _lines.add(TranscriptLine(isUser, t));
    }
    transcript.value = List.of(_lines);
  }

  // ================= تشغيل الصوت =================
  Future<void> _ensurePcm() async {
    if (_pcmReady) return;
    await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(2400);
    _pcmReady = true;
    FlutterPcmSound.start();
  }

  void _goIdle() {
    aiState.value = AiState.idle;
    aiLevel.value = 0;
  }

  Future<void> _playChunk(Uint8List bytes) async {
    if (!_isPlaying) _userText = '';
    if (aiState.value != AiState.speaking) aiState.value = AiState.speaking;

    await _ensurePcm();
    final bd =
        bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
    await FlutterPcmSound.feed(PcmArrayInt16(bytes: bd));
    aiLevel.value = _rms(bytes);

    final ms = bytes.lengthInBytes ~/ 48;
    final now = DateTime.now();
    final base = _playUntil.isAfter(now) ? _playUntil : now;
    _playUntil = base.add(Duration(milliseconds: ms));

    if (!stayInSpeakingUntilClearSpeech) {
      _endSpeakTimer?.cancel();
      _endSpeakTimer = Timer(
        _playUntil.difference(DateTime.now()) +
            const Duration(milliseconds: 150),
        _goIdle,
      );
    }
  }

  Future<void> _stopPlayback() async {
    _endSpeakTimer?.cancel();
    _playUntil = DateTime.now();
    aiLevel.value = 0;
    if (!stayInSpeakingUntilClearSpeech) _goIdle();
    if (_pcmReady) {
      _pcmReady = false;
      await FlutterPcmSound.release();
    }
  }

  Future<void> interrupt() async {
    if (!_isPlaying) return;
    _dropAudio = true;
    _turnText = '';
    _turnCounted = false;
    await _stopPlayback();
    _sfx.play('interrupted.mp3');
    _checkClearSpeech();
  }

  Future<void> _handleServerInterrupted() async {
    final wasPlaying = _isPlaying;
    _turnText = '';
    _turnCounted = false;
    await _stopPlayback();
    _dropAudio = false;
    if (wasPlaying) _sfx.play('interrupted.mp3');
    _checkClearSpeech();
  }

  // ================= الإعدادات والإنهاء =================
  void toggleMute() => muted.value = !muted.value;

  Future<void> setAccent(Accent a) async {
    if (a == accent.value || _disposed) return;
    accent.value = a;
    await _stopPlayback();
    _ready = false;
    _resumeText = _buildResumeText(connectionLost: false);
    await _wsSub?.cancel();
    try {
      await _ch?.sink.close();
    } catch (_) {}
    try {
      await _connect();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  Future<void> stop({bool playEndSound = true}) async {
    if (_disposed) return;
    _disposed = true;
    _setupTimeout?.cancel();
    _endSpeakTimer?.cancel();
    _reconnectTimer?.cancel();
    reconnecting.value = false;
    await _sfx.stopRing();
    if (playEndSound) _sfx.play('call_end.mp3');
    try {
      await _micSub?.cancel();
      await _rec.stop();
      await _rec.dispose();
      await _wsSub?.cancel();
      await _ch?.sink.close();
      if (_pcmReady) await FlutterPcmSound.release();
    } catch (e) {
      debugPrint('stop error: $e');
    }
    _pcmReady = false;
    Future.delayed(const Duration(seconds: 3), _sfx.dispose);
  }
}
