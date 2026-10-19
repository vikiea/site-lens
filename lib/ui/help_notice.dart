import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// Static help that stays dismissed across pages and app restarts.
class SiteLensHelpNotice extends StatelessWidget {
  const SiteLensHelpNotice({
    super.key,
    required this.app,
    required this.noticeId,
    required this.text,
  });

  final AppController app;
  final String noticeId;
  final String text;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      if (app.settings.isNoticeDismissed(noticeId)) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: SiteLensMetrics.sectionGap),
        child: SiteLensPersistentNotice(
          dismissed: false,
          text: text,
          onDismiss: () =>
              safely(context, () => app.dismissHelpNotice(noticeId)),
        ),
      );
    },
  );
}
