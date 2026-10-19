'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {execFile} = require('node:child_process');
const vscode = require('vscode');

const serial = 'emulator-5554';

function androidReady() {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT ||
    path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk');
  const adb = path.join(sdk, 'platform-tools', 'adb.exe');
  return new Promise(resolve => {
    execFile(adb, ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
      {timeout: 5000, windowsHide: true},
      (error, stdout) => resolve(!error && stdout.trim() === '1'));
  });
}

async function waitForApp() {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT ||
    path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk');
  const adb = path.join(sdk, 'platform-tools', 'adb.exe');
  for (let attempt = 0; attempt < 180; attempt++) {
    const running = await new Promise(resolve => {
      execFile(adb, ['-s', serial, 'shell', 'pidof', 'com.muondia.muondia'],
        {timeout: 5000, windowsHide: true},
        (error, stdout) => resolve(!error && /^\d+(\s+\d+)*$/.test(stdout.trim())));
    });
    if (running) return;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error('Flutter no llegó a iniciar el proceso de Muondia en Android.');
}

async function activate(context) {
  if (!vscode.workspace.isTrusted) return;
  const folder = (vscode.workspace.workspaceFolders || []).find(entry => {
    const root = entry.uri.fsPath;
    const pubspec = path.join(root, 'pubspec.yaml');
    return fs.existsSync(path.join(root, 'lib', 'main.dart')) &&
      fs.existsSync(pubspec) &&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(pubspec, 'utf8'));
  });
  if (!folder) return;

  const output = vscode.window.createOutputChannel('Muondia · Inicio');
  context.subscriptions.push(output);
  output.appendLine('Abriendo Muondia...');

  try {
    if (!await androidReady()) {
      output.appendLine('Iniciando Android mediante EmbeDroid.');
      await vscode.commands.executeCommand('embedroid.bootItem', {
        avd: {name: 'Muondia'}
      });
      if (!await androidReady()) {
        throw new Error('Android no está listo después de arrancar el emulador.');
      }
    }

    const active = vscode.debug.activeDebugSession;
    const running = active?.type === 'dart' && active.name === 'Muondia';
    if (!running) {
      output.appendLine('Iniciando Flutter con Dart-Code.');
      const started = await vscode.debug.startDebugging(folder, 'Muondia');
      if (!started) throw new Error('Dart-Code no ha iniciado la depuración.');
    }

    output.appendLine('Esperando a la aplicación Muondia.');
    await waitForApp();
    output.appendLine('Aplicación iniciada. Abriendo la imagen en EmbeDroid.');
    await vscode.commands.executeCommand('embedroid.openEmbedded', {device: {serial}});
    output.appendLine('Muondia iniciada.');
  } catch (error) {
    const message = error?.stack || String(error);
    output.appendLine(message);
    output.show(true);
    vscode.window.showErrorMessage('Muondia: el arranque ha fallado. Consulta la salida Muondia · Inicio.');
  }
}

module.exports = {activate, androidReady};
