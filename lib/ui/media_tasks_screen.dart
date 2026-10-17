import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../media/dlna_service.dart';
import '../media/media_service.dart';
import 'app_controller.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';
import 'app_theme.dart';

/// Durable media task surface. The screen is deliberately independent from a
/// browser tab: a task can be resumed after its source tab is gone.
class MediaTasksScreen extends StatefulWidget {
  const MediaTasksScreen({super.key, required this.app});
  final AppController app;

  @override
  State<MediaTasksScreen> createState() => _MediaTasksScreenState();
}

class _MediaTasksScreenState extends State<MediaTasksScreen> {
  bool busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await safely(context, action);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _refreshNative(MediaTask task) async {
    final native = widget.app.nativeDownloads;
    if (native == null) throw StateError('iOS 不支持原生后台下载');
    final status = await native.status(task.id);
    final state = status['state'] as String?;
    final bytes = (status['bytesDownloaded'] as num?)?.toInt();
    final total = (status['totalBytes'] as num?)?.toInt();
    if (bytes != null) {
      widget.app.mediaTasks.updateProgress(task.id, bytes, totalBytes: total);
    }
    final localUri = status['localUri'] as String?;
    if (localUri != null && localUri.startsWith('file://')) {
      widget.app.mediaTasks.setLocalRef(
        task.id,
        Uri.parse(localUri).toFilePath(),
      );
    }
    if (state == 'paused' && task.state == MediaTaskState.downloading) {
      widget.app.mediaTasks.transition(task.id, MediaTaskState.paused);
    }
    if (state == 'completed' && task.state == MediaTaskState.downloading) {
      widget.app.mediaTasks.transition(task.id, MediaTaskState.completed);
      widget.app.mediaTasks.transition(task.id, MediaTaskState.playable);
    }
    if (mounted) setState(() {});
  }

  Future<void> _play(MediaTask task) async {
    final cached = await widget.app.mediaTasks.cachedFile(task.id);
    if (cached != null) {
      await widget.app.nativeMedia.openLocal(task, cached);
      if (mounted) setState(() {});
      return;
    }
    final candidate = await widget.app.db.mediaCandidate(task.candidateId);
    if (candidate == null) throw StateError('媒体候选已不存在');
    await widget.app.nativeMedia.open(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
      sessionId: 'play_${task.id}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('原生播放器已打开')));
  }

  Future<void> _togglePause(MediaTask task) async {
    final candidate = await widget.app.db.mediaCandidate(task.candidateId);
    if (candidate == null) throw StateError('媒体候选已不存在');
    if (task.state == MediaTaskState.downloading) {
      await widget.app.mediaDownloads.pauseNative(task.id);
    } else if (task.state == MediaTaskState.paused) {
      await widget.app.mediaDownloads.resumeNative(task.id, candidate);
    }
    if (mounted) setState(() {});
  }

  Future<void> _cast(MediaTask task) async {
    final file = await widget.app.mediaTasks.cachedFile(task.id);
    if (file == null) throw StateError('该任务没有可投屏的本地文件');
    final devices = await const DlnaDiscovery().discover();
    if (devices.isEmpty) throw StateError('局域网内没有发现可用的 DLNA 接收端');
    final device = devices.first;
    await DlnaCastController(widget.app.castSessions).cast(
      device: device,
      mediaTaskId: task.id,
      mediaUrl: file.uri,
      localFile: file,
      mime: 'video/mp4',
      title: task.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已投屏到 ${device.name}')));
    }
  }

  Future<void> _export(MediaTask task) async {
    final file = await widget.app.mediaTasks.cachedFile(task.id);
    if (file == null || !file.path.toLowerCase().endsWith('.m3u8')) {
      throw StateError('当前缓存不是可导出的本地 HLS 清单');
    }
    final input = await const HlsPlaylistParser().parseFile(file.uri);
    final result = await widget.app.mediaExports.export(task.id, input);
    if (result.state != ExportState.deliverable) {
      throw StateError(result.errorCode ?? '导出失败');
    }
    final destination = await FilePicker.saveFile(
      bytes: Uint8List(0),
      dialogTitle: '导出 MP4',
      fileName: '${task.id}.mp4',
      mimeType: 'video/mp4',
    );
    if (destination == null) return;
    await widget.app.mediaExports.deliver(result, destination);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('MP4 已交付')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.app.mediaTasks.tasks;
    return SiteLensPageScaffold(
      title: '媒体任务',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          if (widget.app.nativeMedia.active != null)
            SiteLensPanel(
              child: Row(
                children: [
                  const Icon(Icons.play_circle_filled),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '原生播放：${widget.app.nativeMedia.active!.state.name}',
                    ),
                  ),
                  IconButton(
                    tooltip: '暂停',
                    icon: const Icon(Icons.pause),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.pause();
                      if (mounted) setState(() {});
                    }),
                  ),
                  IconButton(
                    tooltip: '继续',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.play();
                      if (mounted) setState(() {});
                    }),
                  ),
                  IconButton(
                    tooltip: '停止',
                    icon: const Icon(Icons.stop),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.stop();
                      if (mounted) setState(() {});
                    }),
                  ),
                ],
              ),
            ),
          SiteLensPanel(
            child: Text(
              '下载、播放和导出任务独立于标签页保存。凭据不会写入任务或缓存；需要登录态时会回到重新授权。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: SiteLensMetrics.sectionGap),
          if (tasks.isEmpty)
            const SiteLensPanel(
              child: ListTile(
                leading: Icon(Icons.download_done),
                title: Text('暂无媒体任务'),
                subtitle: Text('在浏览器的「媒体候选」中选择地址开始缓存。'),
              ),
            ),
          for (final task in tasks) ...[
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(
                  task.state == MediaTaskState.playable
                      ? Icons.play_circle
                      : Icons.downloading,
                ),
                title: Text(
                  task.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${task.state.name} · ${task.bytesDownloaded} bytes${task.errorCode == null ? '' : ' · ${task.errorCode}'}',
                ),
                trailing: PopupMenuButton<String>(
                  enabled: !busy,
                  onSelected: (value) {
                    switch (value) {
                      case 'refresh':
                        unawaited(_run(() => _refreshNative(task)));
                      case 'play':
                        unawaited(_run(() => _play(task)));
                      case 'cast':
                        unawaited(_run(() => _cast(task)));
                      case 'export':
                        unawaited(_run(() => _export(task)));
                      case 'cancel':
                        unawaited(
                          _run(() async {
                            final native = widget.app.nativeDownloads;
                            if (native == null) {
                              throw StateError('iOS 不支持原生后台下载');
                            }
                            await native.cancel(task.id);
                            if (widget.app.mediaTasks.task(task.id)?.state ==
                                MediaTaskState.downloading) {
                              widget.app.mediaTasks.transition(
                                task.id,
                                MediaTaskState.cancelled,
                              );
                            }
                            if (mounted) setState(() {});
                          }),
                        );
                      case 'pause':
                        unawaited(_run(() => _togglePause(task)));
                      case 'delete':
                        unawaited(
                          _run(() async {
                            final native = widget.app.nativeDownloads;
                            if (native != null) await native.delete(task.id);
                            await widget.app.mediaTasks.delete(task.id);
                            if (mounted) setState(() {});
                          }),
                        );
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Text('刷新后台状态'),
                    ),
                    if (task.state == MediaTaskState.playable)
                      const PopupMenuItem(value: 'play', child: Text('原生播放')),
                    if (task.state == MediaTaskState.playable)
                      const PopupMenuItem(
                        value: 'cast',
                        child: Text('DLNA 投屏'),
                      ),
                    if (task.state == MediaTaskState.playable)
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出 MP4'),
                      ),
                    if (task.state == MediaTaskState.downloading)
                      const PopupMenuItem(value: 'pause', child: Text('暂停下载')),
                    if (task.state == MediaTaskState.paused)
                      const PopupMenuItem(value: 'pause', child: Text('继续下载')),
                    if (task.state == MediaTaskState.downloading ||
                        task.state == MediaTaskState.paused)
                      const PopupMenuItem(value: 'cancel', child: Text('取消下载')),
                    const PopupMenuItem(value: 'delete', child: Text('删除任务')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
          ],
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
