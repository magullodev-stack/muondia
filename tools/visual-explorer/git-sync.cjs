'use strict';
const {execFile} = require('node:child_process');

const EXPECTED_REMOTE = /^(?:https:\/\/github\.com\/|git@github\.com:)magullodev-stack\/muondia(?:\.git)?$/i;

function git(root, args) {
  return new Promise((resolve, reject) => {
    execFile('git', ['-C', root, ...args], {
      windowsHide: true,
      timeout: 20000,
      maxBuffer: 1024 * 1024,
      env: {...process.env, GIT_TERMINAL_PROMPT: '0'},
    }, (error, stdout, stderr) => {
      if (error) reject(new Error((stderr || error.message).trim()));
      else resolve(stdout.trim());
    });
  });
}

function counts(value) {
  const match = /^(\d+)\s+(\d+)$/.exec(value.trim());
  if (!match) throw new Error('Git ha devuelto un estado inesperado: ' + value);
  return {ahead: Number(match[1]), behind: Number(match[2])};
}

function createGitSync(root, vscode, output) {
  let running = false;
  let stopped = false;
  let lastError = '';
  const disposables = [];
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 25);
  status.name = 'Muondia Git';
  status.text = '$(sync) Muondia dev';
  status.tooltip = 'GitHub y VS Code: sincronización automática de commits';
  status.command = 'muondia.visual.showSyncLog';
  status.show();
  disposables.push(status);

  async function tick() {
    if (running || stopped) return;
    running = true;
    try {
      const branch = await git(root, ['branch', '--show-current']);
      const remote = await git(root, ['remote', 'get-url', 'origin']);
      if (branch !== 'dev' || !EXPECTED_REMOTE.test(remote)) {
        throw new Error('Rama o remoto incorrecto: se requiere muondia, origin y dev.');
      }
      await git(root, ['fetch', '--quiet', '--no-tags', 'origin', 'dev']);
      const {ahead, behind} = counts(await git(root, [
        'rev-list', '--left-right', '--count', 'HEAD...origin/dev'
      ]));
      if (ahead && behind) {
        throw new Error('Hay commits divergentes. Codex debe integrarlos; no se descarta trabajo.');
      }
      if (behind) {
        // Git impide sobrescribir archivos locales modificados o sin seguimiento.
        await git(root, ['merge', '--ff-only', 'origin/dev']);
        output.appendLine('GitHub → VS Code: cambios de Muondia incorporados.');
      } else if (ahead) {
        // No crear commits de archivos a medio editar.
        await git(root, ['push', 'origin', 'dev']);
        output.appendLine('VS Code → GitHub: commits terminados publicados.');
      }
      if (lastError) output.appendLine('Sincronización recuperada.');
      lastError = '';
      status.text = '$(check) Muondia dev';
      status.tooltip = 'Muondia dev sincronizada (comprobación cada 10 s)';
    } catch (error) {
      const message = String(error.message || error);
      if (lastError !== message) output.appendLine('Sincronización detenida: ' + message);
      lastError = message;
      status.text = '$(warning) Muondia Git';
      status.tooltip = 'Sincronización pendiente: ' + message + '\nPulsa para ver el registro.';
    } finally {
      running = false;
    }
  }

  const interval = setInterval(tick, 10000);
  disposables.push({dispose: () => clearInterval(interval)});
  disposables.push(vscode.window.onDidChangeWindowState(state => {
    if (state.focused) void tick();
  }));
  void tick();
  return {dispose() {
    stopped = true;
    for (const disposable of disposables) disposable.dispose();
  }};
}

module.exports = {createGitSync, counts, EXPECTED_REMOTE};
