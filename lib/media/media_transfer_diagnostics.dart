import 'package:flutter/services.dart';

import '../network/transport.dart';

/// Persist human-readable, allowlisted diagnostics only. Provider exception
/// strings, URL paths, auth headers and proxy endpoints never enter task rows.
String mediaTransferFailureText(Object error) {
  final message = readableError(error);
  if (error is! PlatformException ||
      error.code != 'media_transfer' ||
      error.details is! Map) {
    return message;
  }
  final details = error.details as Map;
  final resource = switch (details['resource'] ?? details['resourceKind']) {
    'manifest' => '清单',
    'key' => '密钥',
    'segment' => '分片',
    'map' => '初始化分片',
    _ => '媒体',
  };
  final phase = switch (details['phase']) {
    'connect' || 'route' => '连接',
    'response_headers' => '响应头',
    'body_read' => '内容',
    'file_io' => '文件写入',
    _ => '未知',
  };
  final route = switch (details['route']) {
    'http_proxy' => 'HTTP 代理',
    'vpn_tun_fake_ip' => 'VPN/TUN',
    'router_fake_ip' => '网关 Fake-IP',
    'public_direct' || 'direct' => '公共直连',
    _ => '未知',
  };
  final reason = switch (details['reason']) {
    'tls_handshake' => 'TLS 握手失败',
    'certificate' || 'hostname' => '证书验证失败',
    'proxy_connect' || 'proxy_connect_status' => '代理连接失败',
    'timeout' => '连接超时',
    'dns' => 'DNS 解析失败',
    'route_changed' => '网络路由已变化',
    _ => '网络连接失败',
  };
  int count(Object? value) => value is int && value >= 0 ? value : 0;
  return '$message\n资源：$resource · 阶段：$phase\n最后路由：$route · 原因：$reason'
      '\n尝试：${count(details['attemptsUsed'])} 次 · 已写入：${count(details['bytesWritten'])} 字节';
}
