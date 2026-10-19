import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

class PlayerGesturesScreen extends StatelessWidget {
  const PlayerGesturesScreen({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => SiteLensPageScaffold(
      title: '播放器手势',
      body: ListView(
        padding: const EdgeInsets.all(SiteLensMetrics.pagePadding),
        children: [
          SiteLensPanel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.swipe_vertical_outlined, size: 20),
                  title: Row(
                    children: [
                      const Text('上下滑动'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PopupMenuButton<PlayerVerticalGestureMode>(
                          tooltip: '选择上下滑动操作',
                          initialValue: app.playerVerticalGesture,
                          onSelected: (value) => safely(
                            context,
                            () => app.setPlayerVerticalGesture(value),
                          ),
                          itemBuilder: (_) => [
                            for (final mode in PlayerVerticalGestureMode.values)
                              PopupMenuItem(
                                value: mode,
                                child: Semantics(
                                  selected: app.playerVerticalGesture == mode,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 28,
                                        child: app.playerVerticalGesture == mode
                                            ? const Icon(Icons.check, size: 18)
                                            : null,
                                      ),
                                      Text(mode.label),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    app.playerVerticalGesture.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.expand_more, size: 20),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _GestureDetails(
                  text:
                      app.playerVerticalGesture ==
                          PlayerVerticalGestureMode.brightnessVolume
                      ? '在画面左半侧上下滑动调节亮度，右半侧调节媒体音量。向上增加，向下减少；从当前亮度和音量开始调节。'
                      : '向上滑动切换下一集，向下滑动切换上一集。滑动超过画面高度的十分之一才会切换；播放列表首尾不再继续切换。',
                ),
                const Divider(height: 1),
                const _GestureHelp(
                  icon: Icons.swipe_outlined,
                  title: '左右滑动',
                  summary: '快进 / 快退',
                  details: '向右滑动快进，向左滑动快退。滑动时预览目标时间，松手后跳转；横向距离按视频总时长换算。尚未取得总时长时不可拖动定位。',
                ),
                const Divider(height: 1),
                const _GestureHelp(
                  icon: Icons.touch_app_outlined,
                  title: '长按',
                  summary: '临时 2 倍速',
                  details: '长按播放画面临时使用 2 倍速，松开后恢复长按前的播放速度。',
                ),
                const Divider(height: 1),
                const _GestureHelp(
                  icon: Icons.ads_click_outlined,
                  title: '双击',
                  summary: '播放 / 暂停',
                  details: '双击播放画面切换播放与暂停；缓冲中仍以播放器实际状态为准。',
                ),
                const Divider(height: 1),
                const _GestureHelp(
                  icon: Icons.pan_tool_alt_outlined,
                  title: '单击',
                  summary: '显示 / 隐藏控制栏',
                  details:
                      '单击画面显示或隐藏控制栏。播放中控制栏会在空闲后自动收起；通过控制栏可打开播放列表、调整倍速或停止播放。',
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _GestureHelp extends StatelessWidget {
  const _GestureHelp({
    required this.icon,
    required this.title,
    required this.summary,
    required this.details,
  });

  final IconData icon;
  final String title;
  final String summary;
  final String details;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        leading: Icon(icon, size: 20),
        title: Text(title),
        trailing: Text(summary, style: Theme.of(context).textTheme.bodySmall),
      ),
      _GestureDetails(text: details),
    ],
  );
}

class _GestureDetails extends StatelessWidget {
  const _GestureDetails({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => SiteLensFoldable(
    child: ExpansionTile(
      title: Text('详情', style: Theme.of(context).textTheme.labelMedium),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
