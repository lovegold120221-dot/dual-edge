import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

class MicVisualizer extends StatelessWidget {
  const MicVisualizer({required this.level, required this.active, super.key});

  final double level;
  final bool active;

  @override
  Widget build(BuildContext context) {
    const barCount = 32;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: active ? 1 : 0,
      child: SizedBox(
        width: 200,
        height: 38,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: List<Widget>.generate(barCount, (index) {
            final mirrored = index < barCount / 2
                ? index
                : barCount - 1 - index;
            final heightFactor = (mirrored / (barCount / 2));
            final dynamicHeight =
                level.clamp(0.0, 1.0) *
                30 *
                (1.2 - heightFactor * heightFactor);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 65),
              width: 3,
              height: 2 + dynamicHeight,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: AppColors.red,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ),
    );
  }
}
