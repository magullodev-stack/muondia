'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const run = promisify(execFile);

const CATALOG = 'lib/development/experiences.json';
const FLAGS = 'lib/development/visual_layers.dart';
const IMAGE = /\.(?:png|jpe?g|webp)$/i;

function readCatalog(root) {
  const file = path.join(root, CATALOG);
  if (!fs.existsSync(file)) return [];
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (data.version !== 1 || !Array.isArray(data.experiences)) {
    throw new Error('Catálogo de Muondia inválido.');
  }
  const owned = new Set(), flags = new Set(), ids = new Set();
  for (const screen of data.experiences) {
    if (!/^[a-z][a-z0-9_-]*$/.test(screen.id || '') ||
        ids.has(screen.id) || !screen.label ||
        !Array.isArray(screen.states) || !Array.isArray(screen.assets)) {
      throw new Error('Pantalla inválida en el catálogo.');
    }
    ids.add(screen.id);
    for (const state of screen.states) {
      if (!/^[a-z][a-z0-9_-]*$/.test(state.id || '') ||
          typeof state.source !== 'string' ||
          !/^lib\/[a-zA-Z0-9_/-]+\.dart$/.test(state.source) ||
          state.source.includes('..')) {
        throw new Error('Estado de pantalla inválido.');
      }
    }
    for (const asset of screen.assets) {
      if (typeof asset.file !== 'string' || typeof asset.flag !== 'string' ||
          !/^assets\/[a-zA-Z0-9_/-]+\.(?:png|jpe?g|webp)$/i.test(asset.file) ||
          asset.file.includes('..') ||
          !/^[a-zA-Z][a-zA-Z0-9]*$/.test(asset.flag) ||
          owned.has(asset.file) || flags.has(asset.flag)) {
        throw new Error('Recurso visual inválido o compartido entre pantallas.');
      }
      owned.add(asset.file);
      flags.add(asset.flag);
    }
  }
  return data.experiences;
}

function visibility(root, flag) {
  const file = path.join(root, FLAGS);
  const src = fs.readFileSync(file, 'utf8');
  const pattern = new RegExp('^\\s*static const bool ' + flag +
    '\\s*=\\s*(true|false)\\s*;', 'gm');
  const matches = [...src.matchAll(pattern)];
  if (matches.length !== 1) throw new Error('Visibilidad de capa no declarada: ' + flag);
  return matches[0][1] === 'true';
}

function createTree(root, vscode) {
  const emitter = new vscode.EventEmitter();
  let screens = [], error = '';
  function refresh() {
    try { screens = readCatalog(root); error = ''; }
    catch (e) { screens = []; error = e.message; }
    emitter.fire();
  }
  const provider = {
    onDidChangeTreeData: emitter.event,
    getChildren(node) {
      if (!node) {
        if (error) return [{kind:'info',id:'error',label:error}];
        if (!screens.length) return [{kind:'info',id:'empty',label:'No hay pantallas declaradas'}];
        const groups = [...new Set(screens.map(s => s.group || 'Pantallas'))];
        return groups.map(label => ({kind:'group',id:'group:'+label,label}));
      }
      if (node.kind === 'group') return screens
        .filter(s => (s.group || 'Pantallas') === node.label)
        .map(s => ({kind:'screen',id:'screen:'+s.id,label:s.label,screen:s}));
      if (node.kind === 'screen') return [
        ...node.screen.states.map(s => ({
          kind:'state',id:'state:'+node.screen.id+':'+s.id,
          label:s.label,screen:node.screen,state:s,
        })),
        ...node.screen.assets.map(a => ({
          kind:'image',id:'image:'+a.file,label:a.name || path.basename(a.file),
          image:a,screen:node.screen,
        })),
      ];
      return [];
    },
    getTreeItem(node) {
      const collapsed = ['group','screen'].includes(node.kind);
      const item = new vscode.TreeItem(
        node.kind === 'group' ? node.label.toLocaleUpperCase('es') : node.label,
        collapsed ? vscode.TreeItemCollapsibleState.Collapsed :
          vscode.TreeItemCollapsibleState.None);
      item.id = node.id;
      if (node.kind === 'group') item.iconPath = new vscode.ThemeIcon('folder');
      else if (node.kind === 'screen') item.iconPath = new vscode.ThemeIcon('window');
      else if (node.kind === 'state') {
        item.iconPath = new vscode.ThemeIcon('circle-outline');
        item.contextValue = 'muondiaState';
        item.command = {command:'muondia.visual.openState',
          title:'Abrir pantalla',arguments:[node]};
      } else if (node.kind === 'image') {
        const exists = fs.existsSync(path.join(root, node.image.file));
        const visible = exists && visibility(root, node.image.flag);
        item.iconPath = new vscode.ThemeIcon(
          !exists ? 'warning' : visible ? 'eye' : 'eye-closed',
          !exists ? new vscode.ThemeColor('editorWarning.foreground') : undefined);
        item.description = !exists ? 'No encontrada' : visible ? 'Visible' : 'Oculta';
        item.contextValue = !exists ? 'muondiaImageMissing' :
          visible ? 'muondiaImageVisible' : 'muondiaImageHidden';
        item.tooltip = node.image.file + ' · ' +
          (exists ? 'El ojo muestra u oculta esta capa en desarrollo.' :
            'No existe el PNG.');
        if (exists) {
          item.resourceUri = vscode.Uri.file(path.join(root,node.image.file));
          item.command = {command:'vscode.open',title:'Abrir imagen',
            arguments:[item.resourceUri]};
        }
      } else item.iconPath = new vscode.ThemeIcon('info');
      return item;
    }
  };
  refresh();
  return {provider,refresh,dispose:()=>emitter.dispose()};
}

async function activate(context) {
  const vscode = require('vscode');
  if (!vscode.workspace.isTrusted) return;
  const folder = (vscode.workspace.workspaceFolders || []).find(f => {
    const manifest = path.join(f.uri.fsPath,'pubspec.yaml');
    return fs.existsSync(manifest) &&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(manifest,'utf8'));
  });
  if (!folder) return;
  const root = folder.uri.fsPath;
  const tree = createTree(root, vscode);
  const output = vscode.window.createOutputChannel('Muondia · Explorador visual');
  context.subscriptions.push(tree,output,
    vscode.window.registerTreeDataProvider('muondia.visual',tree.provider));

  function resolveImage(node) {
    if (!node || node.kind !== 'image') throw new Error('Selecciona una imagen.');
    const screens = readCatalog(root);
    const image = screens.flatMap(s => s.assets).find(a =>
      a.file === node.image.file && a.flag === node.image.flag);
    if (!image) throw new Error('Imagen no declarada en Muondia.');
    const full = path.resolve(root,image.file);
    if (!full.startsWith(path.resolve(root,'assets')+path.sep) ||
        !fs.existsSync(full) || fs.lstatSync(full).isSymbolicLink()) {
      throw new Error('Imagen fuera del proyecto o no disponible.');
    }
    return {image,full};
  }

  async function refreshFlutter() {
    const active = (vscode.debug.sessions || []).some(s =>
      s.type === 'dart' && s.name === 'Muondia');
    if (!active) {
      vscode.window.showInformationMessage('El cambio está guardado. Inicia Muondia para verlo.');
      return;
    }
    try { await vscode.commands.executeCommand('dart.hotReload'); }
    catch (error) {
      output.appendLine('Hot Reload: '+String(error));
      vscode.window.showWarningMessage('Flutter no aplicó el Hot Reload; prueba Hot Restart.');
    }
  }

  async function toggle(node) {
    const {image} = resolveImage(node);
    const file = vscode.Uri.file(path.join(root,FLAGS));
    const doc = await vscode.workspace.openTextDocument(file);
    if (doc.isDirty) throw new Error('Guarda primero visual_layers.dart.');
    const current = visibility(root,image.flag);
    const regex = new RegExp('(^\\s*static const bool ' + image.flag +
      '\\s*=\\s*)(true|false)(\\s*;)', 'gm');
    const matches = [...doc.getText().matchAll(regex)];
    if (matches.length !== 1) throw new Error('Constante visual no encontrada.');
    const match = matches[0];
    const from = match.index + match[1].length;
    const edit = new vscode.WorkspaceEdit();
    edit.replace(file,new vscode.Range(doc.positionAt(from),
      doc.positionAt(from+match[2].length)),current ? 'false' : 'true');
    if (!await vscode.workspace.applyEdit(edit) || !await doc.save()) {
      throw new Error('No se pudo guardar el cambio de visibilidad.');
    }
    tree.refresh();
    await refreshFlutter();
  }

  async function replace(node) {
    const {image,full} = resolveImage(node);
    const selected = await vscode.window.showOpenDialog({
      canSelectFiles:true,canSelectFolders:false,canSelectMany:false,
      openLabel:'Sustituir imagen',
      filters:{Imágenes:['png','jpg','jpeg','webp']},
    });
    if (!selected?.[0] || path.resolve(selected[0].fsPath) === full) return;
    if (path.extname(selected[0].fsPath).toLowerCase() !==
        path.extname(full).toLowerCase()) {
      throw new Error('La imagen nueva debe tener el mismo formato.');
    }
    const bytes = await vscode.workspace.fs.readFile(selected[0]);
    if (bytes.length < 16 || bytes.length > 50*1024*1024 ||
        (IMAGE.test(full) && path.extname(full).toLowerCase() === '.png' &&
         Buffer.from(bytes.subarray(0,8)).toString('hex') !== '89504e470d0a1a0a')) {
      throw new Error('La imagen seleccionada no es válida.');
    }
    const ok = await vscode.window.showWarningMessage(
      '¿Sustituir '+path.basename(full)+'?',
      {modal:true,detail:'Se conserva el nombre y las referencias Dart. Git permite recuperar la versión anterior.'},
      'Sustituir imagen');
    if (ok !== 'Sustituir imagen') return;
    resolveImage(node);
    await vscode.workspace.fs.writeFile(vscode.Uri.file(full),bytes);
    tree.refresh();
    vscode.window.showInformationMessage('Imagen sustituida. Reconstruye Flutter para actualizar el PNG en Android.');
  }

  async function openState(node) {
    if (node?.kind !== 'state') return;
    const found = readCatalog(root)
      .find(s=>s.id === node.screen.id)?.states.find(s=>s.id === node.state.id);
    if (!found || node.screen.id !== 'auth') {
      throw new Error('Esta pantalla aún no tiene previsualización.');
    }
    const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT ||
      path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk');
    const adb = path.join(sdk, 'platform-tools', 'adb.exe');
    if (!fs.existsSync(adb)) throw new Error('No se encuentra adb.exe.');

    let running;
    try {
      const status = await run(adb,
        ['-s', 'emulator-5554', 'shell', 'pidof', 'com.muondia.muondia'],
        {timeout: 5000, windowsHide: true});
      running = status.stdout.trim();
    } catch {
      throw new Error('Inicia Muondia en el emulador antes de abrir su pantalla.');
    }
    if (!/^\d+(\s+\d+)*$/.test(running)) {
      throw new Error('Muondia no está ejecutándose.');
    }
    await run(adb, [
      '-s', 'emulator-5554', 'shell', 'am', 'start',
      '-n', 'com.muondia.muondia/.MainActivity',
      '-a', 'com.muondia.muondia.DEV_OPEN_VISUAL',
      '-f', '0x20000000',
      '--es', 'experience', node.screen.id,
      '--es', 'state', found.id,
    ], {timeout: 8000, windowsHide: true});
  }
  const safe = action => async node => {
    try { await action(node); }
    catch (error) {
      output.appendLine(String(error?.stack || error));
      vscode.window.showErrorMessage('Muondia: '+String(error.message || error));
    }
  };
  context.subscriptions.push(
    vscode.commands.registerCommand('muondia.visual.refresh',tree.refresh),
    vscode.commands.registerCommand('muondia.visual.hide',safe(toggle)),
    vscode.commands.registerCommand('muondia.visual.show',safe(toggle)),
    vscode.commands.registerCommand('muondia.visual.replace',safe(replace)),
    vscode.commands.registerCommand('muondia.visual.openState',safe(openState))
  );
  const watcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(folder,'lib/development/{experiences.json,visual_layers.dart}'));
  const assets = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(folder,'assets/**/*'));
  for (const watched of [watcher,assets]) {
    context.subscriptions.push(watched,watched.onDidCreate(tree.refresh),
      watched.onDidChange(tree.refresh),watched.onDidDelete(tree.refresh));
  }
}
module.exports = {activate,readCatalog,visibility,createTree};
