import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/voice_playback_service.dart';

class VoiceMessage extends StatefulWidget {
  final Message message;
  final bool isSender;
  const VoiceMessage({super.key, required this.message, this.isSender = false});
  @override
  State<VoiceMessage> createState() => _VoiceMessageState();
}

class _VoiceMessageState extends State<VoiceMessage> {
  bool _expanded = false;
  Message get message => widget.message;
  bool get isSender => widget.isSender;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: VoicePlaybackService.instance,
    builder: (context, _) {
      final playback = VoicePlaybackService.instance;
      final active = playback.active == message.id;
      final seconds = ((message.durationMs ?? 0) / 1000).ceil();
      return Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .65,
        ),
        decoration: BoxDecoration(
          color: isSender ? const Color(0xFF95EC69) : Colors.white,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: '语音 $seconds 秒，${active ? '停止' : '点击播放'}',
              button: true,
              child: InkWell(
                key: ValueKey('voice:${message.id}'),
                onTap: message.audioUrl == null
                    ? null
                    : () async {
                        try {
                          await playback.toggle(message.id, message.audioUrl!);
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$error；文字仍可查看')),
                            );
                          }
                        }
                      },
                child: SizedBox(
                  width: (112 + seconds * 2).clamp(112, 230).toDouble(),
                  height: 46,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        if (active && playback.loading)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            active
                                ? Icons.stop_circle_outlined
                                : Icons.volume_up,
                            size: 23,
                          ),
                        const Spacer(),
                        Text('$seconds″', style: const TextStyle(fontSize: 17)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(48, 32),
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? '收起文字' : '查看文字',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF576B95),
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  message.content,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
          ],
        ),
      );
    },
  );
}
