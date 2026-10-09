import 'dart:convert';
import 'dart:io';

final _startedAt = DateTime.now();
var _requestCount = 0;

Future<void> main() async {
  // Вся конфигурация — через переменные окружения.
  final env = Platform.environment;
  // 0.0.0.0 — обязательно, иначе сервер не будет доступен снаружи контейнера.
  final host = env['HOST'] ?? '0.0.0.0';
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final greeting = env['GREETING'] ?? 'Привет из Docker!';
  final appEnv = env['APP_ENV'] ?? 'development';

  final server = await HttpServer.bind(host, port);
  print('Сервер запущен на $host:${server.port} (APP_ENV=$appEnv)');

  // Корректное завершение по Ctrl+C / docker stop.
  ProcessSignal.sigint.watch().listen((_) => _shutdown(server));
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => _shutdown(server));
  }

  await for (final request in server) {
    _requestCount++;
    print('${DateTime.now().toIso8601String()} ${request.method} ${request.uri.path}');

    switch (request.uri.path) {
      case '/':
        _send(request, {
          'message': greeting,
          'endpoints': ['/', '/health', '/info', '/echo?text=...'],
        });
      case '/health':
        _send(request, {'status': 'ok'});
      case '/info':
        _send(request, {
          'hostname': Platform.localHostname, // в Docker = ID контейнера
          'os': Platform.operatingSystem,
          'user': Platform.environment['USER'] ?? 'unknown',
          'appEnv': Platform.environment['APP_ENV'] ?? 'development',
          'dartVersion': Platform.version.split(' ').first,
          'uptimeSeconds': DateTime.now().difference(_startedAt).inSeconds,
          'requests': _requestCount,
        });
      case '/echo':
        _send(request, {'echo': request.uri.queryParameters['text'] ?? ''});
      default:
        _send(request, {'error': 'Not found'}, status: HttpStatus.notFound);
    }
  }
}

void _send(HttpRequest request, Object body, {int status = HttpStatus.ok}) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(const JsonEncoder.withIndent('  ').convert(body))
    ..close();
}

Future<void> _shutdown(HttpServer server) async {
  print('Остановка сервера...');
  await server.close(force: true);
  exit(0);
}
