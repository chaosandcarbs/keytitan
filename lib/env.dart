import 'package:envied/envied.dart';
part 'env.g.dart';

@Envied(path: '.env')
abstract class Env {
  @EnviedField(varName: 'DRIVE_CLIENT_ID', obfuscate: true)
  static final String clientId = _Env.clientId;

  @EnviedField(varName: 'DRIVE_CLIENT_SECRET', obfuscate: true)
  static final String clientSecret = _Env.clientSecret;
}