import 'package:envied/envied.dart';

part 'env.g.dart';

@Envied(path: 'kt.env')
abstract class Env {
  @EnviedField(varName: 'DESKTOP_CLIENT_ID', obfuscate: true)
  static final String desktopClientId = _Env.desktopClientId;

  @EnviedField(varName: 'DESKTOP_CLIENT_SECRET', obfuscate: true)
  static final String desktopClientSecret = _Env.desktopClientSecret;

  @EnviedField(varName: 'ANDROID_CLIENT_ID', obfuscate: true)
  static final String androidClientId = _Env.androidClientId;

  @EnviedField(varName: 'WEB_CLIENT_ID', obfuscate: true)
  static final String webClientId = _Env.webClientId;

  @EnviedField(varName: 'WEB_CLIENT_SECRET', obfuscate: true)
  static final String webClientSecret = _Env.webClientSecret;

  @EnviedField(varName: 'IOS_CLIENT_ID', obfuscate: true)
  static final String iosClientId = _Env.iosClientId;
}
