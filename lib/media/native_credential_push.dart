import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/site_adapter.dart';

/// 原生侧对一次推送的回执。只有身份与代次，没有凭证值。
class NativeCredentialReceipt {
  const NativeCredentialReceipt({
    required this.accepted,
    required this.profileId,
    required this.epoch,
  });

  final bool accepted;
  final int profileId;

  /// 原生侧那次写入的序号，用来对齐两份副本。只前进，不回退。
  final int epoch;

  @override
  String toString() =>
      'NativeCredentialReceipt(profileId=$profileId, epoch=$epoch, accepted=$accepted)';
}

/// 把站点凭证从应用侧推给原生（ADR-0007）。
///
/// 方向是单向的：`push` 写、`clear` 撤、`has` 只回答「有没有」。原生侧没有把
/// 凭证值送回来的通道，应用侧也没有接它的入口——凭证的唯一真相始终是应用自己
/// 持有的那一份（[SiteCredentialStore]）。
///
/// 推送只是把应用侧已经落盘的那一份抄给原生，不改变应用侧的会话；刷新成功之后
/// 再推一次就是另一个动作。
class NativeCredentialPush {
  NativeCredentialPush({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/credentials');

  final MethodChannel _channel;

  /// 原生侧记录格式的版本，与 `SiteCredentialStore.recordVersion` 及原生
  /// `SiteCredentialRecord.RECORD_VERSION` 一致；版本不同就当作没有凭证。
  static const recordVersion = 1;

  /// 把 [credential] 写进原生侧 [profileId] 名下。
  ///
  /// [station] 是这份凭证服务的站点 origin；原生据此判断这条媒体地址该不该带上
  /// 它。为 null 表示不限定站点。
  Future<NativeCredentialReceipt> push(
    int profileId,
    SiteCredential credential, {
    Uri? station,
  }) async {
    if (!credential.isUsable) {
      // 与 `SiteCredentialStore.save` 同一条规则：令牌与 cookie 缺一不可。
      throw const FormatException('站点凭证缺少访问令牌或 cookie');
    }
    final raw = await _channel.invokeMapMethod<String, Object?>('push', {
      'profileId': profileId,
      'credential': encode(credential, station: station),
    });
    return _receipt(raw);
  }

  /// 撤回原生侧那一份（登出、档案删除）。重复调用没有副作用。
  Future<NativeCredentialReceipt> clear(int profileId) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('clear', {
      'profileId': profileId,
    });
    return _receipt(raw);
  }

  /// 原生侧此刻是否持有该档案可用的凭证。只回答有或没有。
  Future<bool> has(int profileId) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('has', {
      'profileId': profileId,
    });
    return raw?['has'] == true;
  }

  /// 原生侧最近一次写入的序号。
  Future<int> epoch() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('epoch');
    return (raw?['epoch'] as num?)?.toInt() ?? 0;
  }

  /// 记录形状。字段名与 `SiteCredentialStore._encode` 及原生
  /// `SiteCredentialRecord` 一一对应，版本号不同即整体不认识。
  static Map<String, Object?> record(
    SiteCredential credential, {
    Uri? station,
  }) => {
    'version': recordVersion,
    'account': credential.account.id,
    'station': station?.origin.toString(),
    'accessToken': credential.accessToken,
    'refreshToken': credential.refreshToken,
    'cookies': credential.cookies,
    'installationStamp': credential.installationStamp,
    'expiresAt': credential.expiresAt?.toUtc().toIso8601String(),
  };

  /// 通道上原样传的字符串；与 [record] 同一份内容。
  static String encode(SiteCredential credential, {Uri? station}) =>
      jsonEncode(record(credential, station: station));

  NativeCredentialReceipt _receipt(Map<String, Object?>? raw) =>
      NativeCredentialReceipt(
        accepted: raw?['accepted'] == true,
        profileId: (raw?['profileId'] as num?)?.toInt() ?? -1,
        epoch: (raw?['epoch'] as num?)?.toInt() ?? 0,
      );
}
