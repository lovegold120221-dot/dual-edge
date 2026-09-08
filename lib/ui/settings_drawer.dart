import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_theme.dart';
import '../data/models/translation_settings.dart';
import '../data/translation_data.dart';
import '../services/ondevice_llm_service.dart';
import '../state/app_controller.dart';

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final languages = <String>{
      ...availableLanguages,
      settings.language1,
      settings.language2,
    }.toList()..sort();

    return Drawer(
      width: MediaQuery.sizeOf(context).width.clamp(320, 430).toDouble(),
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 10, 8),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  _SectionTitle(
                    title: 'Translation setup',
                    trailing: controller.connected
                        ? const Text(
                            'Stop translation to edit',
                            style: TextStyle(
                              color: AppColors.red,
                              fontSize: 11,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('language1-${settings.language1}'),
                    initialValue: settings.language1,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Staff Language (Language 1)',
                    ),
                    items: languages
                        .map(
                          (language) => DropdownMenuItem<String>(
                            value: language,
                            child: Text(
                              language,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: controller.connected
                        ? null
                        : (value) =>
                              _update(settings.copyWith(language1: value)),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey('language2-${settings.language2}'),
                    initialValue: settings.language2,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Guest Language (Language 2)',
                    ),
                    items: languages
                        .map(
                          (language) => DropdownMenuItem<String>(
                            value: language,
                            child: Text(
                              language,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: controller.connected || settings.autoDetect
                        ? null
                        : (value) =>
                              _update(settings.copyWith(language2: value)),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                    title: const Text('Auto-detect Guest Language'),
                    value: settings.autoDetect,
                    onChanged: controller.connected
                        ? null
                        : (value) =>
                              _update(settings.copyWith(autoDetect: value)),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    key: ValueKey('voice-${settings.voice}'),
                    initialValue: TranslationSettings.normalizeVoice(
                      settings.voice,
                    ),
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'AI Voice'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: TranslationSettings.voiceMale,
                        child: Text('Male'),
                      ),
                      DropdownMenuItem<String>(
                        value: TranslationSettings.voiceFemale,
                        child: Text('Female'),
                      ),
                    ],
                    onChanged: controller.connected
                        ? null
                        : (value) => _update(
                            settings.copyWith(
                              voice: TranslationSettings.normalizeVoice(value),
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: ValueKey('topic-${settings.topic}'),
                    initialValue: settings.topic,
                    enabled: !controller.connected,
                    decoration: const InputDecoration(
                      labelText: 'Conversation topic',
                      prefixIcon: Icon(Icons.topic_outlined),
                    ),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (value) =>
                        _update(settings.copyWith(topic: value.trim())),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<bool>(
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Icons.medical_services_outlined),
                        label: Text('Medical'),
                      ),
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Icons.forum_outlined),
                        label: Text('General'),
                      ),
                    ],
                    selected: <bool>{settings.medicalMode},
                    onSelectionChanged: controller.connected
                        ? null
                        : (selection) => _update(
                            settings.copyWith(medicalMode: selection.first),
                          ),
                  ),
                  const SizedBox(height: 28),
                  if (OnDeviceLlmService.isSupported) ...<Widget>[
                    const _SectionTitle(title: 'On-device models'),
                    const SizedBox(height: 10),
                    _ModelStatusRow(
                      label: 'Translator (eb-translator)',
                      status: controller.onDeviceModelStatus,
                      progress: controller.onDeviceDownloadProgress,
                    ),
                    _ModelStatusRow(
                      label: 'Speech recognition (whisper)',
                      status: controller.sttModelStatus,
                      progress: controller.sttDownloadProgress,
                    ),
                    _ModelStatusRow(
                      label: 'Speech synthesis (Supertonic)',
                      status: controller.ttsModelStatus,
                      progress: controller.ttsDownloadProgress,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Models download once on Wi-Fi (translator ≈2.5 GB, '
                      'the rest is small), then STT, translation, and TTS '
                      'all run fully offline on this phone — no Wi-Fi '
                      'needed afterwards. No account or sign-in needed — '
                      'everything runs locally.',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 28),
                  ],
                  _SectionTitle(
                    title: 'Translation history',
                    trailing: Text(
                      '${controller.history.length} saved',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: controller.history.isEmpty
                              ? null
                              : () => _export(context),
                          icon: const Icon(Icons.ios_share_rounded, size: 18),
                          label: const Text('Export PDF'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: controller.history.isEmpty
                              ? null
                              : controller.clearHistory,
                          icon: const Icon(
                            Icons.delete_sweep_outlined,
                            size: 18,
                          ),
                          label: const Text('Clear'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (controller.history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        'No history yet. Start a translation to see it here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  else
                    ...controller.history
                        .take(50)
                        .map(
                          (item) => Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHigh,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Text(
                                      DateFormat(
                                        'HH:mm',
                                      ).format(item.timestamp),
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const Spacer(),
                                    Flexible(
                                      child: Text(
                                        '${item.language1} → ${item.language2}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.blue,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.sourceText,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppColors.text),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  item.translatedText,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Powered by Eburon AI',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _update(TranslationSettings next) {
    controller.updateSettings(next);
  }

  static String _onDeviceStatusText(String? status, double? progress) {
    switch (status) {
      case 'ready':
        return 'ready · offline';
      case 'downloading':
      case 'loading':
        if (progress == null) return 'preparing…';
        return '${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%';
      case 'download-failed':
        return 'download failed';
      default:
        return 'not downloaded';
    }
  }

  Future<void> _export(BuildContext context) async {
    try {
      await controller.exportHistory();
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _ModelStatusRow extends StatelessWidget {
  const _ModelStatusRow({
    required this.label,
    required this.status,
    required this.progress,
  });

  final String label;
  final String? status;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final downloading = status == 'downloading' || status == 'loading';
    final currentProgress = progress;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: AppColors.text, fontSize: 13),
                ),
              ),
              Text(
                SettingsDrawer._onDeviceStatusText(status, currentProgress),
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
          if (downloading && currentProgress != null) ...<Widget>[
            const SizedBox(height: 5),
            LinearProgressIndicator(value: currentProgress.clamp(0.0, 1.0)),
          ],
        ],
      ),
    );
  }
}
