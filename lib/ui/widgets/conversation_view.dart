import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/models/conversation_turn.dart';

class ConversationView extends StatelessWidget {
  const ConversationView({
    required this.turns,
    required this.language1,
    required this.language2,
    required this.scrollController,
    super.key,
  });

  final List<ConversationTurn> turns;
  final String language1;
  final String language2;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    if (turns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 80, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
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
              ),
              const SizedBox(height: 24),
              const Text(
                'Ready to translate',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: Text(
                  '$language1  ⇄  $language2',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 15),
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: const Text(
                  'Tap play or the microphone to start a real-time voice session.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 84, 16, 184),
      itemCount: turns.length,
      itemBuilder: (context, index) {
        final turn = turns[index];
        return _TurnBlock(turn: turn);
      },
    );
  }
}

class _TurnBlock extends StatelessWidget {
  const _TurnBlock({required this.turn});

  final ConversationTurn turn;

  @override
  Widget build(BuildContext context) {
    final isInput = turn.role == ConversationRole.user;
    final transcription = turn.transcription?.trim() ?? '';
    final detected = turn.detectedLanguage?.trim() ?? '';
    final visibleText = turn.visibleText;
    return Align(
      alignment: isInput ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        width: MediaQuery.sizeOf(context).width > 700
            ? 620
            : MediaQuery.sizeOf(context).width * 0.9,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        decoration: BoxDecoration(
          color: isInput ? AppColors.surface : const Color(0xFF0F2031),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isInput ? AppColors.border : const Color(0xFF1B527C),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  isInput ? Icons.mic_none_rounded : Icons.translate_rounded,
                  size: 15,
                  color: isInput ? AppColors.muted : AppColors.blue,
                ),
                const SizedBox(width: 7),
                Text(
                  isInput ? 'INPUT' : 'TRANSLATION',
                  style: TextStyle(
                    color: isInput ? AppColors.muted : AppColors.blue,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                if (!isInput && detected.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      '· heard $detected'.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 9),
            if (!isInput && transcription.isNotEmpty) ...<Widget>[
              Text(
                transcription,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 14,
                  height: 1.35,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 7),
            ],
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: visibleText),
                  if (!turn.isFinal)
                    const TextSpan(
                      text: ' ▌',
                      style: TextStyle(color: AppColors.blue),
                    ),
                ],
              ),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 17,
                height: 1.42,
              ),
            ),
            if (!turn.isFinal) ...<Widget>[
              const SizedBox(height: 9),
              const SizedBox(
                width: 16,
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
