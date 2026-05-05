import 'package:flutter/services.dart';

class ForegroundService {
  static const _channel = MethodChannel('com.example.teamspeak_apk/service');

  static Future<bool> start({String title = 'TeamSpeak', String text = 'Connected'}) async {
    try {
      final result = await _channel.invokeMethod('start', {'title': title, 'text': text});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> update({String title = 'TeamSpeak', String text = 'Connected'}) async {
    try {
      final result = await _channel.invokeMethod('update', {'title': title, 'text': text});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stop() async {
    try {
      final result = await _channel.invokeMethod('stop');
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
