'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');

async function activate() {
  if (!vscode.workspace.isTrusted) return;
  const folder = (vscode.workspace.workspaceFolders || []).find(entry => {
    const root = entry.uri.fsPath;
    const pubspec = path.join(root, 'pubspec.yaml');
    return fs.existsSync(path.join(root, 'lib', 'main.dart')) &&
      fs.existsSync(pubspec) &&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(pubspec, 'utf8'));
  });
  if (!folder) return;
  if (vscode.debug.sessions.some(session =>
    session.type === 'dart' && session.name === 'Muondia')) return;

  try {
    const started = await vscode.debug.startDebugging(folder, 'Muondia');
    if (!started) {
      vscode.window.showWarningMessage('Muondia: no se pudo iniciar Flutter. Consulta el panel de depuración.');
    }
  } catch (error) {
    vscode.window.showErrorMessage('Muondia: ' + error.message);
  }
}

module.exports = {activate};
