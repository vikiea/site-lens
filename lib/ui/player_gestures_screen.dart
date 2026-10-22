import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

class PlayerGesturesScreen extends StatefulWidget {
  const PlayerGesturesScreen({super.key, required this.app});

  final AppController app;

  @override
  State<PlayerGesturesScreen> createState() => _PlayerGesturesScreenState();
}

class _PlayerGesturesScreenState extends State<PlayerGesturesScreen> {
  final _accordion = SiteLensAccordionController();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) => SiteLensPageScaffold(
      title: '播放器手势',
      body: Padding(
        padding: const EdgeInsets.all(SiteLensMetrics.pagePadding),
        child: SiteLensPanel(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SiteLensAccordion(
                key: const ValueKey('gesture-help-vertical'),
                id: 'vertical',
                controller: _accordion,
                leading: const Icon(Icons.swipe_vertical_outlined, size: 18),
                title: _VerticalGestureSetting(app: widget.app),
                details: (_) => _GestureDetailText(
                  text:
                      widget.app.playerVerticalGesture ==
                          PlayerVerticalGestureMode.brightnessVolume
                      ? '在画面左半侧上下滑动调节亮度，右半侧调节媒体音量。向上增加，向下减少；从当前亮度和音量开始调节。'
                      : '向上滑动切换下一集，向下滑动切换上一集。滑动超过画面高度的十分之一才会切换；播放列表首尾不再继续切换。',
                ),
              ),
              const SiteLensPanelDivider(),
              _GestureHelp(
                id: 'horizontal',
                controller: _accordion,
                icon: Icons.swipe_outlined,
                title: '左右滑动',
                summary: '快进 / 快退',
                details: '向右滑动快进，向左滑动快退。滑动时预览目标时间，松手后跳转；横向距离按视频总时长换算。尚未取得总时长时不可拖动定位。',
              ),
              const SiteLensPanelDivider(),
              _GestureHelp(
                id: 'long-press',
                controller: _accordion,
                icon: Icons.touch_app_outlined,
                title: '长按',
                summary: '临时 2 倍速',
                details: '长按播放画面临时使用 2 倍速，松开后恢复长按前的播放速度。',
              ),
              const SiteLensPanelDivider(),
              _GestureHelp(
                id: 'double-tap',
                controller: _accordion,
                icon: Icons.ads_click_outlined,
                title: '双击',
                summary: '播放 / 暂停',
                details: '双击播放画面切换播放与暂停；缓冲中仍以播放器实际状态为准。',
              ),
              const SiteLensPanelDivider(),
              _GestureHelp(
                id: 'tap',
                controller: _accordion,
                icon: Icons.pan_tool_alt_outlined,
                title: '单击',
                summary: '显示 / 隐藏控制栏',
                details: '单击画面显示或隐藏控制栏。播放中控制栏会在空闲后自动收起；通过控制栏可打开播放列表、调整倍速或停止播放。',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _VerticalGestureSetting extends StatelessWidget {
  const _VerticalGestureSetting({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const label = '上下滑动';
      final painter = TextPainter(
        text: TextSpan(text: label, style: DefaultTextStyle.of(context).style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      final fitsInline =
          constraints.maxWidth >=
          painter.width +
              SiteLensMetrics.formGap +
              kMinInteractiveDimension +
              SiteLensMetrics.formGap * 2;
      painter.dispose();
      final selector = SiteLensMenuSelector<PlayerVerticalGestureMode>(
        label: '选择上下滑动操作',
        value: app.playerVerticalGesture,
        onSelected: (value) =>
            safely(context, () => app.setPlayerVerticalGesture(value)),
        options: [
          for (final mode in PlayerVerticalGestureMode.values)
            SiteLensMenuOption(value: mode, label: mode.label),
        ],
      );
      if (fitsInline) {
        return Row(
          children: [
            const Text(label),
            const SizedBox(width: SiteLensMetrics.formGap),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: selector,
              ),
            ),
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(label),
          const SizedBox(height: SiteLensMetrics.itemGap),
          Align(alignment: AlignmentDirectional.centerEnd, child: selector),
        ],
      );
    },
  );
}

class _GestureHelp extends StatelessWidget {
  const _GestureHelp({
    required this.id,
    required this.controller,
    required this.icon,
    required this.title,
    required this.summary,
    required this.details,
  });

  final IconData icon;
  final String id;
  final SiteLensAccordionController controller;
  final String title;
  final String summary;
  final String details;

  @override
  Widget build(BuildContext context) => SiteLensAccordion(
    key: ValueKey('gesture-help-$id'),
    id: id,
    controller: controller,
    leading: Icon(icon, size: SiteLensMetrics.compactIconSize),
    title: Text(title),
    trailingBuilder: (context, expanded) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.36,
          ),
          child: Text(
            summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: SiteLensMetrics.listGap),
        Icon(
          expanded ? Icons.expand_less : Icons.expand_more,
          size: SiteLensMetrics.compactIconSize,
        ),
      ],
    ),
    details: (_) => _GestureDetailText(text: details),
  );
}

class _GestureDetailText extends StatelessWidget {
  const _GestureDetailText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}
