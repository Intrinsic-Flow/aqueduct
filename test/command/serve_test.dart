import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' as yaml;
import 'package:pub_semver/pub_semver.dart';

import 'cli_helpers.dart';

void main() {
  Terminal terminal;
  CLITask task;

  setUp(() async {
    terminal = await Terminal.createProject();
    await terminal.getDependencies(offline: true);
  });

  tearDown(() async {
    await task?.process?.stop(0);
    Terminal.deleteTemporaryDirectory();
  });

  test("Served application starts and responds to route", () async {
    task = terminal.startAqueductCommand("serve", []);
    await task.hasStarted;

    expect(terminal.output, contains("Port: 8888"));
    expect(terminal.output, contains("config.yaml"));

    var thisPubspec = yaml.loadYaml(new File.fromUri(Directory.current.uri.resolve("pubspec.yaml")).readAsStringSync());
    var thisVersion = new Version.parse(thisPubspec["version"]);
    expect(terminal.output, contains("CLI Version: $thisVersion"));
    expect(terminal.output, contains("Aqueduct project version: $thisVersion"));

    var result = await http.get("http://localhost:8888/example");
    expect(result.statusCode, 200);

    task.process.stop(0);
    expect(await task.exitCode, 0);
  });

  test("Ensure we don't find the base ApplicationChannel class", () async {
    terminal.addOrReplaceFile("lib/application_test.dart", "import 'package:aqueduct/aqueduct.dart';");

    task = terminal.startAqueductCommand("serve", []);
    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));
    expect(terminal.output, contains("No ApplicationChannel subclass"));
  });

  test("Exception throw during initializeApplication halts startup", () async {
    terminal.modifyFile("lib/channel.dart", (contents) {
      return contents.replaceFirst("extends ApplicationChannel {", """extends ApplicationChannel {
static Future initializeApplication(ApplicationOptions x) async { throw new Exception("error"); }            
      """);
    });

    task = terminal.startAqueductCommand("serve", []);

    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));
    expect(terminal.output, contains("Application failed to start"));
    expect(terminal.output, contains("Exception: error")); // error generated
    expect(terminal.output, contains("TestChannel.initializeApplication")); // stacktrace
  });

  test("Start with valid SSL args opens https server", () async {
    var certFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.cert.pem"));
    var keyFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.key.pem"));

    certFile.copySync(terminal.workingDirectory.uri.resolve("server.crt").path);
    keyFile.copySync(terminal.workingDirectory.uri.resolve("server.key").path);

    task = terminal.startAqueductCommand("serve",
        ["--ssl-key-path", "server.key", "--ssl-certificate-path", "server.crt"]);
    await task.hasStarted;

    var completer = new Completer();
    var socket = await SecureSocket.connect("localhost", 8888, onBadCertificate: (_) => true);
    var request = "GET /example HTTP/1.1\r\nConnection: close\r\nHost: localhost\r\n\r\n";
    socket.add(request.codeUnits);

    socket.listen((bytes) => completer.complete(bytes));
    var httpResult = new String.fromCharCodes(await completer.future);
    expect(httpResult, contains("200 OK"));
    await socket.close();
  });

  test("Start without one of SSL values throws exception", () async {
    var certFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.cert.pem"));
    var keyFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.key.pem"));

    certFile.copySync(terminal.workingDirectory.uri.resolve("server.crt").path);
    keyFile.copySync(terminal.workingDirectory.uri.resolve("server.key").path);

    task = terminal.startAqueductCommand("serve", ["--ssl-key-path", "server.key"]);
    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));

    task = terminal.startAqueductCommand("serve", ["--ssl-certificate-path", "server.crt"]);
    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));
  });

  test("Start with invalid SSL values throws exceptions", () async {
    var keyFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.key.pem"));
    keyFile.copySync(terminal.workingDirectory.uri.resolve("server.key").path);

    var badCertFile = new File.fromUri(terminal.workingDirectory.uri.resolve("server.crt"));
    badCertFile.writeAsStringSync("foobar");

    task = terminal.startAqueductCommand("serve",
        ["--ssl-key-path", "server.key", "--ssl-certificate-path", "server.crt"]);
    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));
  });

  test("Can't find SSL file, throws exception", () async {
    var keyFile = new File.fromUri(new Directory("ci").uri.resolve("aqueduct.key.pem"));
    keyFile.copySync(terminal.workingDirectory.uri.resolve("server.key").path);

    task = terminal.startAqueductCommand("serve",
        ["--ssl-key-path", "server.key", "--ssl-certificate-path", "server.crt"]);
    task.hasStarted.catchError((_) => null);
    expect(await task.exitCode, isNot(0));
  });

  test("Run application with invalid code fails with error", () async {
    terminal.modifyFile("lib/channel.dart", (contents) {
      return contents.replaceFirst("import", "importasjakads");
    });

    task = terminal.startAqueductCommand("serve", []);
    task.hasStarted.catchError((_) => null);

    expect(await task.exitCode, isNot(0));
    expect(terminal.output, contains("unexpected token"));
  });
}