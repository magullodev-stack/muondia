'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');
const {createGitSync} = require('./git-sync.cjs');

const CATALOG = 'lib/development/experiences.json';

function readCatalog(root) {
  const file = path.join(root, CATALOG);
  if (!fs.existsSync(file)) return [];
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(data.experiences)) throw new Error('Falta experiences en el catálogo.');
  return data.experiences.filter(item =>
    typeof item.id === 'string' && typeof item.label === 'string' &&
    Array.isArray(item.states));
}

function images(root, dirs) {
  const found = [];
  for (const dir of dirs || []) {
    if (typeof dir !== 'string' || !/^assets\/[a-zA-Z0-9_/-]+$/.test(dir) ||
      dir.split('/').includes('..')) continue;
    const folder = path.join(root, ...dir.split('/'));
    if (!fs.existsSync(folder) || !fs.statSync(folder).isDirectory()) continue;
    for (const item of fs.readdirSync(folder, {withFileTypes: true})) {
      if (item.isFile() && /\.(png|jpe?g|webp)$/i.test(item.name)) {
        found.push({label:item.name,file:path.join(folder,item.name)});
      }
    }
  }
  return found;
}

function explorer(root) {
  const change = new vscode.EventEmitter();
  let entries = [];
  let error = '';
  function refresh() {
    try {
      entries = readCatalog(root);
      error = '';
    } catch (e) {
      entries = [];
      error = e.message;
    }
    change.fire();
  }
  const provider = {
    onDidChangeTreeData: change.event,
    getTreeItem(node) {
      const item = new vscode.TreeItem(node.label,
        node.children ? vscode.TreeItemCollapsibleState.Collapsed :
          vscode.TreeItemCollapsibleState.None);
      item.id = node.id;
      item.iconPath = new vscode.ThemeIcon(node.icon || 'circle-outline');
      if (node.file) {
        item.resourceUri = vscode.Uri.file(node.file);
        item.command = {command:'vscode.open',title:'Abrir imagen',
          arguments:[vscode.Uri.file(node.file)]};
      }
      return item;
    },
    getChildren(node) {
      if (node) return node.children || [];
      if (error) return [{id:'error',label:error,icon:'warning'}];
      if (!entries.length) return [{
        id:'empty',label:'Todavía no hay pantallas declaradas',
        icon:'info'
      }];
      const groups = new Map();
      for (const exp of entries) {
        const group = exp.group || 'Pantallas';
        if (!groups.has(group)) groups.set(group, []);
        groups.get(group).push({
          id:'screen:'+exp.id,label:exp.label,icon:'window',
          children:[
            ...exp.states.map(state=>({
              id:'state:'+exp.id+':'+state.id,
              label:state.label || state.id,icon:'symbol-event'
            })),
            ...images(root, exp.assetDirectories).map(file=>({
              id:'asset:'+file.file,label:file.label,file:file.file,icon:'file-media'
            }))
          ]
        });
      }
      return [...groups].map(([label,children])=>({
        id:'group:'+label,label,children,icon:'folder'
      }));
    }
  };
  refresh();
  return {provider,refresh,dispose:()=>change.dispose()};
}

async function activate(context) {
  const folder = (vscode.workspace.workspaceFolders || []).find(f => {
    const manifest = path.join(f.uri.fsPath, 'pubspec.yaml');
    return fs.existsSync(manifest) &&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(manifest, 'utf8'));
  });
  if (!folder || !vscode.workspace.isTrusted) return;

  const root = folder.uri.fsPath;
  const channel = vscode.window.createOutputChannel('Muondia');
  const tree = explorer(root);
  context.subscriptions.push(channel,tree,
    vscode.window.registerTreeDataProvider('muondia.visual',tree.provider),
    vscode.commands.registerCommand('muondia.visual.refresh',tree.refresh),
    vscode.commands.registerCommand('muondia.visual.showSyncLog',()=>channel.show(true)));

  // Sin proceso externo permanente: solo comprobaciones Git breves mientras VS Code esté abierto.
  context.subscriptions.push(createGitSync(root,vscode,channel));

  const watcher = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(folder, CATALOG));
  const assets = vscode.workspace.createFileSystemWatcher(
    new vscode.RelativePattern(folder, 'assets/**/*'));
  for (const watched of [watcher,assets]) {
    context.subscriptions.push(watched,
      watched.onDidCreate(tree.refresh),
      watched.onDidChange(tree.refresh),
      watched.onDidDelete(tree.refresh));
  }
}

module.exports = {activate,readCatalog,images};
