'use strict';
const fs = require('node:fs');
const path = require('node:path');

const CATALOG = 'lib/development/experiences.json';
const LAYERS = 'lib/development/visual_layers.dart';
const ID = /^[a-z][a-zA-Z0-9_-]*$/;
const FLAG = /^[a-z][a-zA-Z0-9]*$/;
const IMAGE = /^assets\/[a-zA-Z0-9_/-]+\.png$/;
const SOURCE = /^lib\/[a-zA-Z0-9_/-]+\.dart$/;
const PNG_MAGIC = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function safePath(root, relative) {
  if (typeof relative !== 'string' ||
      relative.split('/').some(part => !part || part === '..' || part === '.')) {
    throw new Error('Ruta visual no permitida.');
  }
  return path.join(root, ...relative.split('/'));
}

function readCatalog(root) {
  const file = path.join(root, CATALOG);
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (doc.version !== 1 || !Array.isArray(doc.experiences)) {
    throw new Error('El catálogo visual de Muondia no es válido.');
  }
  const screens = new Set();
  const assets = new Set();
  const flags = new Set();
  for (const experience of doc.experiences) {
    if (!ID.test(experience.id) || screens.has(experience.id) ||
        typeof experience.label !== 'string' ||
        typeof experience.group !== 'string' ||
        !Array.isArray(experience.states) ||
        !Array.isArray(experience.assets)) {
      throw new Error('Pantalla visual duplicada o inválida.');
    }
    screens.add(experience.id);
    const stateIds = new Set();
    for (const state of experience.states) {
      if (!ID.test(state.id) || stateIds.has(state.id) ||
          !SOURCE.test(state.source) || state.source.includes('..')) {
        throw new Error('Estado visual inválido.');
      }
      stateIds.add(state.id);
      safePath(root, state.source);
    }
    for (const asset of experience.assets) {
      if (typeof asset.name !== 'string' || !asset.name.trim() ||
          !IMAGE.test(asset.file) || asset.file.includes('..') ||
          !FLAG.test(asset.flag) ||
          assets.has(asset.file) || flags.has(asset.flag)) {
        throw new Error('Capa de imagen duplicada o inválida.');
      }
      safePath(root, asset.file);
      assets.add(asset.file);
      flags.add(asset.flag);
    }
  }
  return doc;
}

function layerPattern(flag) {
  if (!FLAG.test(flag)) throw new Error('Identificador de capa inválido.');
  return new RegExp('(^[ \\t]*static const bool[ \\t]+' +
    flag + '[ \\t]*=[ \\t]*)(true|false)([ \\t]*;)', 'm');
}

function layerVisible(root, flag) {
  const text = fs.readFileSync(path.join(root, LAYERS), 'utf8');
  const match = text.match(layerPattern(flag));
  if (!match) throw new Error('La capa no está declarada: ' + flag);
  return match[2] === 'true';
}

function setLayerVisible(root, flag, visible) {
  const filename = path.join(root, LAYERS);
  const source = fs.readFileSync(filename, 'utf8');
  const pattern = layerPattern(flag);
  if (!pattern.test(source)) throw new Error('La capa no está declarada: ' + flag);
  const changed = source.replace(pattern,
    (_match, prefix, _old, suffix) =>
      prefix + (visible ? 'true' : 'false') + suffix);
  if (changed !== source) fs.writeFileSync(filename, changed, 'utf8');
  return changed !== source;
}

function backupPath(root, asset) {
  return safePath(root, '.muondia/visual-backups/' + asset.file);
}

function assertRegularImage(file) {
  const info = fs.lstatSync(file);
  if (!info.isFile() || info.size === 0 || info.size > 25 * 1024 * 1024) {
    throw new Error('La imagen debe ser un archivo PNG de hasta 25 MB.');
  }
  const fd = fs.openSync(file, 'r');
  try {
    const magic = Buffer.alloc(8);
    if (fs.readSync(fd, magic, 0, 8, 0) !== 8 ||
        !magic.equals(PNG_MAGIC)) {
      throw new Error('El archivo elegido no es PNG.');
    }
  } finally {
    fs.closeSync(fd);
  }
}

function makeTree(root, vscode) {
  const emitter = new vscode.EventEmitter();
  let catalog;
  let error = '';

  function refresh() {
    try {
      catalog = readCatalog(root);
      error = '';
    } catch (e) {
      catalog = null;
      error = e.message;
    }
    emitter.fire();
  }

  function item(node) {
    const collapsible = node.kind === 'group' ||
      node.kind === 'screen' || node.kind === 'images';
    const treeItem = new vscode.TreeItem(node.label,
      collapsible ? vscode.TreeItemCollapsibleState.Collapsed :
        vscode.TreeItemCollapsibleState.None);
    treeItem.id = node.id;

    if (node.kind === 'group') {
      treeItem.iconPath = new vscode.ThemeIcon('folder',
        new vscode.ThemeColor('charts.blue'));
      treeItem.description = node.count + ' pantalla(s)';
    } else if (node.kind === 'screen') {
      treeItem.iconPath = new vscode.ThemeIcon('device-mobile');
    } else if (node.kind === 'state') {
      treeItem.iconPath = new vscode.ThemeIcon('code');
      treeItem.tooltip = 'Abrir el código Flutter de este estado';
      treeItem.command = {
        command: 'vscode.open',
        title: 'Abrir código de la pantalla',
        arguments: [vscode.Uri.file(safePath(root, node.state.source))]
      };
    } else if (node.kind === 'images') {
      treeItem.iconPath = new vscode.ThemeIcon('layers');
      treeItem.description = String(node.assets.length);
    } else if (node.kind === 'asset') {
      const visible = layerVisible(root, node.asset.flag);
      treeItem.iconPath = new vscode.ThemeIcon(visible ? 'eye' : 'eye-closed',
        new vscode.ThemeColor(visible ? 'charts.green' : 'descriptionForeground'));
      treeItem.description = visible ? 'visible' : 'oculta';
      treeItem.tooltip = node.asset.file +
        '\nOjo: mostrar/ocultar sin borrar la imagen';
      treeItem.contextValue = 'muondiaVisualAsset';
      treeItem.resourceUri = vscode.Uri.file(safePath(root, node.asset.file));
      treeItem.command = {
        command: 'vscode.open',
        title: 'Abrir imagen original',
        arguments: [treeItem.resourceUri]
      };
    } else {
      treeItem.iconPath = new vscode.ThemeIcon('warning');
    }
    return treeItem;
  }

  const provider = {
    onDidChangeTreeData: emitter.event,
    getTreeItem: item,
    getChildren(node) {
      if (node?.kind === 'images') {
        return node.assets.map(asset => ({
          kind: 'asset', label: asset.name, asset, id: 'asset:' + asset.flag
        }));
      }
      if (node?.kind === 'screen') {
        return [
          ...node.experience.states.map(state => ({
            kind: 'state', label: state.label, state,
            id: 'state:' + node.experience.id + ':' + state.id
          })),
          {
            kind: 'images', label: 'Capas de imagen',
            assets: node.experience.assets,
            id: 'images:' + node.experience.id
          }
        ];
      }
      if (node?.kind === 'group') {
        return node.experiences.map(exp => ({
          kind: 'screen', label: exp.label, experience: exp,
          id: 'screen:' + exp.id
        }));
      }
      if (!catalog) {
        return [{kind: 'error', label: error, id: 'error'}];
      }
      if (!catalog.experiences.length) {
        return [{kind: 'error', label: 'No hay pantallas declaradas', id: 'empty'}];
      }
      const groups = new Map();
      for (const exp of catalog.experiences) {
        if (!groups.has(exp.group)) groups.set(exp.group, []);
        groups.get(exp.group).push(exp);
      }
      return [...groups].map(([label, experiences]) => ({
        kind: 'group', label, experiences, count: experiences.length,
        id: 'group:' + label
      }));
    }
  };
  refresh();
  return {provider, refresh, dispose: () => emitter.dispose()};
}

function validateSelection(root, node) {
  if (!node || node.kind !== 'asset' || !node.asset) {
    throw new Error('Selecciona una capa de imagen del explorador.');
  }
  const doc = readCatalog(root);
  const declared = doc.experiences
    .flatMap(screen => screen.assets)
    .find(asset => asset.flag === node.asset.flag &&
      asset.file === node.asset.file);
  if (!declared) throw new Error('Esta imagen no pertenece a Muondia.');
  return declared;
}

async function activate(context) {
  const vscode = require('vscode');
  if (!vscode.workspace.isTrusted) return;
  const workspace = (vscode.workspace.workspaceFolders || []).find(folder => {
    const file = path.join(folder.uri.fsPath, 'pubspec.yaml');
    return fs.existsSync(file) &&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(file, 'utf8'));
  });
  if (!workspace) return;
  const root = workspace.uri.fsPath;
  const explorer = makeTree(root, vscode);
  const handle = fn => async (...args) => {
    try {
      await fn(...args);
    } catch (error) {
      await vscode.window.showErrorMessage('Muondia: ' + error.message);
    }
  };

  context.subscriptions.push(explorer,
    vscode.window.registerTreeDataProvider('muondia.visual', explorer.provider),
    vscode.commands.registerCommand('muondia.visual.refresh', explorer.refresh),
    vscode.commands.registerCommand('muondia.visual.toggle', handle(async node => {
      const asset = validateSelection(root, node);
      const uri = vscode.Uri.file(path.join(root, LAYERS));
      if (vscode.workspace.textDocuments.some(doc =>
        doc.uri.toString() === uri.toString() && doc.isDirty)) {
        throw new Error('Guarda visual_layers.dart antes de cambiar el ojo.');
      }
      const enabled = layerVisible(root, asset.flag);
      setLayerVisible(root, asset.flag, !enabled);
      explorer.refresh();
      vscode.window.setStatusBarMessage(
        asset.name + ': ' + (enabled ? 'oculta' : 'visible') +
          ' · Flutter Hot Reload', 5000);
    })),
    vscode.commands.registerCommand('muondia.visual.replace', handle(async node => {
      const asset = validateSelection(root, node);
      const target = safePath(root, asset.file);
      const picked = await vscode.window.showOpenDialog({
        canSelectFiles: true, canSelectFolders: false, canSelectMany: false,
        title: 'Sustituir ' + asset.name + ' · Muondia',
        filters: {'Imágenes PNG': ['png']}
      });
      if (!picked?.length) return;
      const input = picked[0].fsPath;
      if (path.resolve(input).toLowerCase() ===
          path.resolve(target).toLowerCase()) return;
      assertRegularImage(input);
      assertRegularImage(target);
      const approval = await vscode.window.showWarningMessage(
        'Sustituir ' + asset.name +
          '? Guardaré el original localmente y podrás restaurarlo.',
        {modal: true}, 'Sustituir');
      if (approval !== 'Sustituir') return;
      const backup = backupPath(root, asset);
      fs.mkdirSync(path.dirname(backup), {recursive: true});
      if (!fs.existsSync(backup)) {
        fs.copyFileSync(target, backup, fs.constants.COPYFILE_EXCL);
      }
      fs.copyFileSync(input, target);
      explorer.refresh();
      vscode.window.showInformationMessage(
        'Imagen sustituida. Reconstruye Flutter para actualizar los recursos en Android.');
    })),
    vscode.commands.registerCommand('muondia.visual.restore', handle(async node => {
      const asset = validateSelection(root, node);
      const backup = backupPath(root, asset);
      if (!fs.existsSync(backup)) {
        throw new Error('No hay una copia local anterior de esta imagen.');
      }
      assertRegularImage(backup);
      fs.copyFileSync(backup, safePath(root, asset.file));
      explorer.refresh();
      vscode.window.showInformationMessage(
        'Imagen original restaurada. Reconstruye Flutter para verla en Android.');
    }))
  );

  for (const pattern of [
    'lib/development/experiences.json',
    'lib/development/visual_layers.dart',
    'assets/auth/**/*'
  ]) {
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(workspace, pattern));
    context.subscriptions.push(
      watcher,
      watcher.onDidCreate(explorer.refresh),
      watcher.onDidChange(explorer.refresh),
      watcher.onDidDelete(explorer.refresh)
    );
  }
}

module.exports = {activate, readCatalog, layerVisible, setLayerVisible,
  assertRegularImage, safePath};
