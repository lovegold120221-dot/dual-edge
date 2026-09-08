import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../state/app_controller.dart';
import 'settings_drawer.dart';
import 'widgets/conversation_view.dart';
import 'widgets/mic_visualizer.dart';

class TranslatorScreen extends StatefulWidget {
  const TranslatorScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _scrollController = ScrollController();
  String _lastTurnSignature = '';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleScroll() {
    final turns = widget.controller.turns;
    final signature = turns.isEmpty
        ? ''
        : '${turns.length}:${turns.last.text.length}:'
              '${turns.last.translation?.length ?? 0}:'
              '${turns.last.transcription?.length ?? 0}:'
              '${turns.last.isFinal}';
    if (signature == _lastTurnSignature) return;
    _lastTurnSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    _scheduleScroll();
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      endDrawer: SettingsDrawer(controller: controller),
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: ConversationView(
                turns: controller.turns,
                language1: controller.settings.language1,
                language2: controller.settings.language2,
                scrollController: _scrollController,
              ),
            ),
            Positioned(top: 0, left: 0, right: 0, child: _header(controller)),
            if (controller.lastError != null)
              Positioned(
                top: 66,
                left: 12,
                right: 12,
                child: _ErrorBanner(
                  message: controller.lastError!,
                  onClose: controller.disconnect,
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _ControlTray(controller: controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppController controller) {
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.92),
        border: const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Transform.scale(
              scale: 1.27,
              child: Image.asset(
                'assets/branding/app_logo.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Dual Translate',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const Text(
                  'Real-time native voice translator',
                  style: TextStyle(color: AppColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (controller.connected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.green.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: <Widget>[
                  Icon(Icons.circle, size: 7, color: AppColors.green),
                  SizedBox(width: 5),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: Color(0xFFA8DAB5),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            icon: const Icon(Icons.tune_rounded, size: 27),
          ),
        ],
      ),
    );
  }
}

class _ControlTray extends StatefulWidget {
  const _ControlTray({required this.controller});

  final AppController controller;

  @override
  State<_ControlTray> createState() => _ControlTrayState();
}

class _ControlTrayState extends State<_ControlTray> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final micActive = controller.connected && !controller.micMuted;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            AppColors.background.withValues(alpha: 0),
            AppColors.background,
            AppColors.background,
          ],
          stops: const <double>[0, 0.28, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MicVisualizer(level: controller.micLevel, active: micActive),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(27),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _RoundAction(
                        tooltip: controller.connected
                            ? controller.micMuted
                                  ? 'Unmute microphone'
                                  : 'Mute microphone'
                            : 'Connect and start microphone',
                        icon: controller.micMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        active: micActive,
                        activeColor: AppColors.red,
                        pulse: controller.micLevel,
                        onPressed: controller.connected
                            ? () {
                                setState(() {
                                  controller.micMuted = !controller.micMuted;
                                });
                              }
                            : null,
                      ),
                      const SizedBox(width: 9),
                      _RoundAction(
                        tooltip: controller.outputMuted
                            ? 'Unmute audio output'
                            : 'Mute audio output',
                        icon: controller.outputMuted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        active:
                            controller.aiSpeaking && !controller.outputMuted,
                        activeColor: AppColors.blue,
                        onPressed: controller.connected
                            ? () {
                                setState(() {
                                  controller.outputMuted =
                                      !controller.outputMuted;
                                });
                              }
                            : null,
                      ),
                      const SizedBox(width: 9),
                      _RoundAction(
                        tooltip: 'Reset session logs',
                        icon: Icons.refresh_rounded,
                        onPressed: controller.clearHistory,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                Column(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(27),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: _RoundAction(
                        tooltip: controller.connected
                            ? 'Stop translation'
                            : 'Start translation',
                        icon: controller.connected
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        active: controller.connected,
                        activeColor: controller.connected
                            ? AppColors.blueDark
                            : AppColors.blue,
                        onPressed: controller.connected
                            ? controller.disconnect
                            : () {
                                setState(() {
                                  controller.connect();
                                });
                              },
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedOpacity(
                      opacity: controller.connected || controller.connecting
                          ? 1
                          : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        controller.connecting ? 'Connecting…' : 'Ready',
                        style: const TextStyle(
                          color: AppColors.blue,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.tooltip,
    required this.icon,
    this.active = false,
    this.activeColor = AppColors.blue,
    this.pulse = 0,
    this.spin = false,
    this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final double pulse;
  final bool spin;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: active ? activeColor : AppColors.surfaceHigh,
          foregroundColor: active
              ? activeColor.computeLuminance() > 0.35
                    ? AppColors.black
                    : AppColors.blue
              : AppColors.muted,
          disabledBackgroundColor: AppColors.surfaceHigh.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        icon: Icon(icon),
      ),
    );
    final pulsing = pulse <= 0
        ? button
        : Container(
            padding: EdgeInsets.all(pulse.clamp(0, 1) * 7),
            decoration: BoxDecoration(
              color: AppColors.red.withValues(
                alpha: (pulse.clamp(0, 1) * 0.25),
              ),
              shape: BoxShape.circle,
            ),
            child: button,
          );
    if (!spin) return pulsing;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      onEnd: () {},
      builder: (context, value, child) =>
          Transform.rotate(angle: value * 6.28318, child: child),
      child: pulsing,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 9, 6, 9),
        decoration: BoxDecoration(
          color: const Color(0xFF391B15),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppColors.red),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Colors.black45, blurRadius: 18),
          ],
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.error_outline_rounded, color: AppColors.red),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFFFFC0AA), fontSize: 12),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
