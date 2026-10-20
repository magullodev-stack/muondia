'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const run = promisify(execFile);

const CATALOG = 'lib/development/experiences.json';
const FLAGS = 'lib/development/visual_layers.dart';
const DEVICE = 'emulator-5554';
const APP = 'com.muondia.muondia';
const IMAGE = /\.(png|jpe?g|webp)$/i;

function inside(root, relative) {
  if (typeof relative !== 'string' || relative.split('/').some(x =>
    !x || x === '.' || x === '..' || x.startsWith('.')) ||
    /[\\:*?"<>|\x00-\x1f]/.test(relative)) {
    throw new Error('Ruta visual no permitida.');
  }
  const target = path.resolve(root, ...relative.split('/'));
  if (!target.startsWith(path.resolve(root) + path.sep)) {
    throw new Error('Ruta fuera de Muondia.');
  }
  return target;
}

function scanImages(root, directory, depth = 0) {
  if (depth > 8) throw new Error('Carpeta visual demasiado profunda.');
  const folder = inside(root, directory);
  if (!fs.existsSync(folder)) return [];
  if (!fs.lstatSync(folder).isDirectory() ||
      fs.lstatSync(folder).isSymbolicLink()) {
    throw new Error('Carpeta visual no válida: ' + directory);
  }
  const images = [];
  for (const entry of fs.readdirSync(folder, {withFileTypes: true})) {
    if (entry.isSymbolicLink() || entry.name.startsWith('.')) continue;
    const relative = directory + '/' + entry.name;
    if (entry.isDirectory()) {
      images.push(...scanImages(root, relative, depth + 1));
    } else if (entry.isFile() && IMAGE.test(entry.name)) {
      images.push(relative);
    }
  }
  return images.sort();
}

function readCatalog(root) {
  const file = inside(root, CATALOG);
  if (!fs.existsSync(file)) return [];
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (doc.version !== 1 || !Array.isArray(doc.experiences)) {
    throw new Error('Catálogo de Muondia inválido.');
  }
  const ids = new Set(), owned = new Set(), flags = new Set();
  const dirs = [];
  return doc.experiences.map(screen => {
    if (!/^[a-z][a-z0-9_-]*$/.test(screen.id || '') ||
        ids.has(screen.id) || !screen.label || !screen.group ||
        !Array.isArray(screen.states) || !Array.isArray(screen.assets)) {
      throw new Error('Pantalla del catálogo inválida.');
    }
    ids.add(screen.id);
    const states = new Set();
    for (const state of screen.states) {
      if (!/^[a-z][a-z0-9_-]*$/.test(state.id || '') ||
          states.has(state.id) ||
          !/^lib\/[a-zA-Z0-9_/-]+\.dart$/.test(state.source || '') ||
          state.source.includes('..')) throw new Error('Estado inválido.');
      states.add(state.id);
      inside(root, state.source);
    }
    const declared = new Map();
    for (const asset of screen.assets) {
      if (typeof asset.file !== 'string' || !/^assets\/[a-zA-Z0-9_/-]+\.(png|jpe?g|webp)$/i.test(asset.file) ||
          typeof asset.flag !== 'string' || !/^[a-zA-Z][a-zA-Z0-9]*$/.test(asset.flag) ||
          declared.has(asset.file) || owned.has(asset.file) ||
          flags.has(asset.flag)) throw new Error('Capa visual duplicada o inválida.');
      inside(root, asset.file);
      declared.set(asset.file, asset);
      owned.add(asset.file);
      flags.add(asset.flag);
    }
    const folders = screen.assetDirectories ||
      [...new Set(screen.assets.map(a => path.posix.dirname(a.file)))];
    if (!Array.isArray(folders)) throw new Error('Carpetas visuales inválidas.');
    const found = [];
    for (const folder of folders) {
      if (typeof folder !== 'string' ||
          !/^assets\/[a-zA-Z0-9_/-]+$/.test(folder) ||
          folder.includes('..') || dirs.some(other =>
            folder === other || folder.startsWith(other + '/') ||
            other.startsWith(folder + '/'))) {
        throw new Error('Carpetas visuales duplicadas o solapadas.');
      }
      dirs.push(folder);
      found.push(...scanImages(root, folder));
    }
    for (const asset of found) {
      if (owned.has(asset) && !declared.has(asset)) {
        throw new Error('Imagen compartida entre pantallas: ' + asset);
      }
      owned.add(asset);
    }
    return {
      ...screen,
      assets: [
        ...screen.assets,
        ...found.filter(file => !declared.has(file)).map(file => ({
          file, name: path.posix.basename(file), flag: null
        }))
      ],
    };
  });
}

function visible(root, flag) {
  if (!/^[a-zA-Z][a-zA-Z0-9]*$/.test(flag || '')) {
    throw new Error('La imagen todavía no tiene una capa controlable.');
  }
  const src = fs.readFileSync(inside(root, FLAGS), 'utf8');
  const regex = new RegExp('^[ \\t]*static const bool[ \\t]+' +
    flag + '[ \\t]*=[ \\t]*(true|false)[ \\t]*;', 'gm');
  const matches = [...src.matchAll(regex)];
  if (matches.length !== 1) throw new Error('Falta la capa: ' + flag);
  return matches[0][1] === 'true';
}

function catalogRealReady(root) {
  try {
    return JSON.parse(fs.readFileSync(inside(root, CATALOG), 'utf8'))
      .realFlowAvailable === true;
  } catch { return false; }
}

function createTree(root, vscode) {
  const changed = new vscode.EventEmitter();
  let screens = [], error = '', observed = null;
  let fingerprint = '';

  function snapshot() {
    const paths = [CATALOG, FLAGS];
    for (const screen of screens) {
      for (const state of screen.states) paths.push(state.source);
      for (const asset of screen.assets) paths.push(asset.file);
    }
    return JSON.stringify([...new Set(paths)].sort().map(file => {
      try {
        const stat = fs.statSync(inside(root, file));
        return [file, stat.size, stat.mtimeMs];
      } catch { return [file, null]; }
    }));
  }
  function refresh() {
    try { screens = readCatalog(root); error = ''; }
    catch (e) { screens = []; error = e.message; }
    fingerprint = snapshot();
    changed.fire();
  }
  function pollFiles() {
    // Se relee la carpeta, no solo las imágenes previamente catalogadas.
    let next;
    try {
      const fresh = readCatalog(root);
      const before = screens;
      screens = fresh;
      next = snapshot();
      if (next === fingerprint) {
        screens = before;
        return;
      }
      error = '';
    } catch (e) {
      screens = []; error = e.message;
      next = error;
      if (next === fingerprint) return;
    }
    fingerprint = next;
    changed.fire();
  }
  function setObserved(value) {
    const old = JSON.stringify(observed);
    const next = JSON.stringify(value);
    if (old !== next) {
      observed = value;
      changed.fire();
    }
  }
  const active = (s, state) => observed?.mode === 'preview' &&
    observed.experience === s.id && (!state || observed.state === state);
  const provider = {
    onDidChangeTreeData: changed.event,
    getChildren(node) {
      if (!node) {
        const modes = [
          {kind:'mode',id:'mode:preview',label:'Previsualización segura',mode:'preview'},
          {kind:'mode',id:'mode:real',label:'Recorrido real',mode:'real'}
        ];
        if (error) return [...modes,{kind:'info',id:'error',label:error}];
        const groups = [...new Set(screens.map(s => s.group || 'Pantallas'))];
        return [
          ...modes,
          ...groups.map(label => ({kind:'group',id:'group:'+label,label}))
        ];
      }
      if (node.kind === 'group') {
        return screens.filter(s => s.group === node.label).map(s => ({
          kind:'screen',id:'screen:'+s.id,label:s.label,screen:s
        }));
      }
      if (node.kind === 'screen') {
        return [
          ...node.screen.states.map(s => ({
            kind:'state',id:'state:'+node.screen.id+':'+s.id,
            label:s.label,screen:node.screen,state:s
          })),
          ...node.screen.assets.map(a => ({
            kind:'image',id:'image:'+a.file,label:a.name || path.posix.basename(a.file),
            image:a,screen:node.screen
          }))
        ];
      }
      return [];
    },
    getTreeItem(node) {
      const collapse = ['group','screen'].includes(node.kind);
      const item = new vscode.TreeItem(
        node.kind === 'group' ? node.label.toLocaleUpperCase('es') : node.label,
        collapse ? vscode.TreeItemCollapsibleState.Collapsed :
          vscode.TreeItemCollapsibleState.None
      );
      item.id = node.id;
      if (node.kind === 'mode') {
        const selected = observed?.mode === node.mode;
        const unavailable = node.mode === 'real' && !catalogRealReady(root);
        item.iconPath = new vscode.ThemeIcon(
          node.mode === 'preview' ? 'beaker' : unavailable ? 'lock' : 'play-circle',
          selected ? new vscode.ThemeColor('charts.yellow') : undefined
        );
        item.description = unavailable ? 'requiere Firebase' :
          selected ? '● ACTIVO' : node.mode === 'preview' ? 'sin IA' : 'con servicios reales';
        item.tooltip = unavailable
          ? 'El recorrido real no está configurado en Muondia. No se simula un acceso.'
          : node.mode === 'preview'
          ? 'Abrir Auth sin autenticación ni llamadas a IA'
          : 'Abrir expresamente el recorrido real; puede utilizar IA';
        item.command = {command:'muondia.visual.mode',title:'Seleccionar modo',
          arguments:[node.mode]};
      } else if (node.kind === 'group') {
        const selected = screens.some(s => s.group === node.label && active(s));
        item.iconPath = new vscode.ThemeIcon(selected ? 'folder-opened' : 'folder',
          new vscode.ThemeColor(selected ? 'charts.yellow' : 'charts.blue'));
        if (selected) item.description = '● EN EL EMULADOR';
      } else if (node.kind === 'screen') {
        const selected = active(node.screen);
        item.iconPath = new vscode.ThemeIcon(selected ? 'eye' : 'window',
          selected ? new vscode.ThemeColor('charts.yellow') : undefined);
        if (selected) item.description = '● PANTALLA ABIERTA';
      } else if (node.kind === 'state') {
        const selected = active(node.screen,node.state.id);
        item.iconPath = new vscode.ThemeIcon(selected ? 'circle-filled' : 'circle-outline',
          selected ? new vscode.ThemeColor('charts.yellow') : undefined);
        if (selected) item.description = '● ESTADO ACTIVO';
        item.contextValue = 'muondiaState';
        item.command = {command:'muondia.visual.openState',
          title:'Abrir pantalla',arguments:[node]};
      } else if (node.kind === 'image') {
        const file = inside(root,node.image.file);
        const exists = fs.existsSync(file);
        const pending = !node.image.flag;
        const shown = exists && !pending && visible(root,node.image.flag);
        item.iconPath = new vscode.ThemeIcon(
          !exists ? 'warning' : pending ? 'clock' : shown ? 'file-media' : 'eye-closed',
          !exists ? new vscode.ThemeColor('editorWarning.foreground') : undefined
        );
        item.description = !exists ? 'No encontrada' : pending ? '⏳ Pendiente' :
          shown ? '' : 'Oculta';
        item.contextValue = !exists ? 'muondiaImageMissing' :
          pending ? 'muondiaImagePending' :
          shown ? 'muondiaImageVisible' : 'muondiaImageHidden';
        item.tooltip = node.image.file + (pending
          ? ' · No hay una capa de visibilidad declarada aún.'
          : ' · Ojo para mostrar/ocultar; botón derecho para otras acciones.');
        if (exists) {
          item.resourceUri = vscode.Uri.file(file);
          item.command = {command:'vscode.open',title:'Abrir imagen',
            arguments:[item.resourceUri]};
        }
      } else {
        item.iconPath = new vscode.ThemeIcon('info');
      }
      return item;
    }
  };
  refresh();
  return {provider,refresh,pollFiles,setObserved,
    get observed() { return observed; },
    dispose:()=>changed.dispose()};
}

function imageReferences(root, image) {
  const result = [];
  const roots = ['lib','test','integration_test','docs'];
  const fileTypes = /\.(dart|md|json|yaml|yml)$/i;
  function visit(folder, depth = 0) {
    if (!fs.existsSync(folder) || depth > 24) return;
    for (const item of fs.readdirSync(folder,{withFileTypes:true})) {
      if (item.name.startsWith('.') || item.isSymbolicLink()) continue;
      const file = path.join(folder,item.name);
      if (item.isDirectory()) visit(file,depth + 1);
      else if (item.isFile() && fileTypes.test(file)) {
        if (fs.statSync(file).size > 2 * 1024 * 1024) throw new Error('Archivo grande: '+file);
        const src = fs.readFileSync(file,'utf8');
        if (src.includes(image) || src.includes(path.posix.basename(image))) {
          result.push({file,src});
        }
      }
    }
  }
  for (const folder of roots) visit(path.join(root,folder));
  for (const file of ['README.md','pubspec.yaml']) {
    const full = path.join(root,file);
    if (fs.existsSync(full)) {
      const src=fs.readFileSync(full,'utf8');
      if (src.includes(image)||src.includes(path.posix.basename(image))) result.push({file:full,src});
    }
  }
  return result;
}

async function android(root, ...args) {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT ||
    path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk');
  const adb = path.join(sdk,'platform-tools','adb.exe');
  if (!fs.existsSync(adb)) throw new Error('No se encuentra ADB del emulador Muondia.');
  const result=await run(adb,['-s',DEVICE,...args],{timeout:5000,windowsHide:true});
  return result.stdout.trim();
}
async function observeDevice(root) {
  try {
    const pid=await android(root,'shell','pidof',APP);
    if (!/^\d+(\s+\d+)*$/.test(pid)) return null;
    const state=await android(root,'shell','run-as',APP,
      'cat','files/muondia_active_visual.txt');
    const match=/^(preview|real):([a-z][a-z0-9_-]*):([a-z][a-z0-9_-]*)$/.exec(state);
    if (!match) return null;
    const screens=readCatalog(root);
    const screen=screens.find(s=>s.id===match[2]);
    if (!screen?.states.some(s=>s.id===match[3])) return null;
    return {mode:match[1],experience:match[2],state:match[3]};
  } catch { return null; }
}

async function activate(context) {
  const vscode = require('vscode');
  if (!vscode.workspace.isTrusted) return;
  const folder=(vscode.workspace.workspaceFolders||[]).find(f=>{
    const manifest=path.join(f.uri.fsPath,'pubspec.yaml');
    return fs.existsSync(manifest)&&
      /^name:\s*muondia\s*$/m.test(fs.readFileSync(manifest,'utf8'));
  });
  if (!folder) return;
  const root=folder.uri.fsPath;
  const tree=createTree(root,vscode);
  const output=vscode.window.createOutputChannel('Muondia · Explorador visual');
  const safe=callback=>async (...args)=>{
    try { await callback(...args); }
    catch (e) {
      output.appendLine(String(e?.stack||e));
      vscode.window.showErrorMessage('Muondia: '+String(e.message||e));
    }
  };
  async function preview(screen,state) {
    if (!readCatalog(root).some(s=>s.id===screen &&
      s.states.some(x=>x.id===state))) throw new Error('Vista no registrada.');
    await android(root,'shell','am','start',
      '-n',APP+'/.MainActivity','-a',APP+'.DEV_OPEN_VISUAL',
      '-f','0x20000000','--es','experience',screen,'--es','state',state);
  }
  function resolveImage(node) {
    if (node?.kind!=='image') throw new Error('Selecciona una imagen.');
    const current=readCatalog(root).flatMap(s=>s.assets)
      .find(a=>a.file===node.image.file&&a.flag===node.image.flag);
    if (!current) throw new Error('Imagen no declarada en Muondia.');
    const full=inside(root,current.file);
    if (!fs.existsSync(full) || !fs.lstatSync(full).isFile() ||
        fs.lstatSync(full).isSymbolicLink()) throw new Error('Imagen no disponible.');
    return {image:current,full};
  }
  async function toggle(node) {
    const {image}=resolveImage(node);
    if (!image.flag) throw new Error('Imagen pendiente: falta registrar la capa.');
    const uri=vscode.Uri.file(inside(root,FLAGS));
    const doc=await vscode.workspace.openTextDocument(uri);
    if (doc.isDirty) throw new Error('Guarda visual_layers.dart primero.');
    const now=visible(root,image.flag);
    const pattern=new RegExp('(^[ \\t]*static const bool[ \\t]+'+
      image.flag+'[ \\t]*=[ \\t]*)(true|false)([ \\t]*;)','gm');
    const matches=[...doc.getText().matchAll(pattern)];
    if (matches.length!==1) throw new Error('Capa no reconocida.');
    const hit=matches[0],offset=hit.index+hit[1].length;
    const edit=new vscode.WorkspaceEdit();
    edit.replace(uri,new vscode.Range(doc.positionAt(offset),
      doc.positionAt(offset+hit[2].length)),now?'false':'true');
    if (!await vscode.workspace.applyEdit(edit) || !await doc.save()) {
      throw new Error('No se pudo guardar la visibilidad.');
    }
    tree.refresh(); // Dart-Code gestiona el Hot Reload al guardar.
  }
  async function replace(node) {
    const {image,full}=resolveImage(node);
    const picked=await vscode.window.showOpenDialog({canSelectFiles:true,
      canSelectFolders:false,canSelectMany:false,
      filters:{Imágenes:['png','jpg','jpeg','webp']}});
    if (!picked?.length || path.resolve(picked[0].fsPath)===full) return;
    if (path.extname(picked[0].fsPath).toLowerCase()!==
        path.extname(full).toLowerCase()) throw new Error('Usa el mismo formato.');
    const bytes=await vscode.workspace.fs.readFile(picked[0]);
    if (bytes.length<12 || bytes.length>50*1024*1024 ||
        (path.extname(full).toLowerCase()==='.png' &&
        Buffer.from(bytes.subarray(0,8)).toString('hex')!=='89504e470d0a1a0a')) {
      throw new Error('Imagen no válida.');
    }
    const ok=await vscode.window.showWarningMessage('¿Sustituir '+path.basename(full)+'?',
      {modal:true,detail:'Se mantiene el nombre y la referencia Dart. Git conserva el original.'},
      'Sustituir imagen');
    if (ok!=='Sustituir imagen') return;
    resolveImage(node);
    await vscode.workspace.fs.writeFile(vscode.Uri.file(full),bytes);
    tree.refresh();
    vscode.window.showInformationMessage(
      'PNG actualizado. Reconstruye Flutter para ver los nuevos recursos en Android.');
  }
  async function rename(node) {
    const {image,full}=resolveImage(node);
    const oldName=path.basename(full);
    const nextName=await vscode.window.showInputBox({
      title:'Cambiar nombre de imagen',value:oldName,
      prompt:'Se corregirán las referencias Dart y el catálogo visual.',
      validateInput:s=>!s||s.startsWith('.')||!IMAGE.test(s)||
        /[\\/]/.test(s)||path.extname(s).toLowerCase()!==
          path.extname(oldName).toLowerCase()
        ? 'Usa un nombre válido sin cambiar el formato.' : undefined
    });
    if (!nextName||nextName===oldName) return;
    const newFile=path.join(path.dirname(full),nextName);
    if (fs.existsSync(newFile)) throw new Error('Ya existe: '+nextName);
    const nextAsset=path.posix.join(path.posix.dirname(image.file),nextName);
    const refs=imageReferences(root,image.file);
    const sourceFiles=new Map(refs.map(x=>[x.file,x.src]));
    const catFile=inside(root,CATALOG);
    sourceFiles.set(catFile,fs.readFileSync(catFile,'utf8'));
    const changes=[];
    for (const [file,src] of sourceFiles) {
      // No se adivinan referencias basadas solo en nombre o rutas dinámicas.
      const rest=src.split(image.file).join('');
      if (rest.includes(oldName)) {
        throw new Error('Referencia ambigua en '+path.relative(root,file)+'. Renombrado cancelado.');
      }
      const updated=src.split(image.file).join(nextAsset);
      if (updated!==src) changes.push({file,src,updated});
    }
    const documents=[];
    for (const change of changes) {
      const doc=await vscode.workspace.openTextDocument(vscode.Uri.file(change.file));
      if (doc.isDirty || doc.getText()!==change.src) {
        throw new Error('Guarda '+path.basename(change.file)+' antes de renombrar.');
      }
      documents.push({doc,change});
    }
    const ok=await vscode.window.showWarningMessage('¿Renombrar '+oldName+'?',
      {modal:true,detail:'Se actualizarán las rutas declaradas de Muondia.'},
      'Cambiar nombre');
    if (ok!=='Cambiar nombre') return;
    for (const {doc,change} of documents) {
      if (doc.isDirty || fs.readFileSync(change.file,'utf8')!==change.src) {
        throw new Error('Las referencias cambiaron. Operación cancelada.');
      }
    }
    if (fs.existsSync(newFile)) throw new Error('El nombre ya está ocupado.');
    const edit=new vscode.WorkspaceEdit();
    for (const {doc,change} of documents) {
      edit.replace(doc.uri,new vscode.Range(doc.positionAt(0),
        doc.positionAt(change.src.length)),change.updated);
    }
    edit.renameFile(vscode.Uri.file(full),vscode.Uri.file(newFile),
      {overwrite:false});
    if (!await vscode.workspace.applyEdit(edit)) {
      throw new Error('No se pudo actualizar el PNG y sus referencias.');
    }
    for (const {doc} of documents) await doc.save();
    tree.refresh();
  }
  async function remove(node) {
    const {image,full}=resolveImage(node);
    if (image.flag) {
      throw new Error('Esta imagen pertenece a una capa Flutter. Hay que retirar primero el widget y sus referencias; no se borrará a ciegas.');
    }
    if (imageReferences(root,image.file).length) {
      throw new Error('La imagen tiene referencias en el proyecto; no se puede borrar.');
    }
    const ok=await vscode.window.showWarningMessage(
      '¿Enviar '+path.basename(full)+' a la papelera?',
      {modal:true,detail:'Solo se elimina una imagen sin referencias ni capa registrada.'},
      'Eliminar PNG sin uso');
    if (ok!=='Eliminar PNG sin uso') return;
    resolveImage(node);
    if (imageReferences(root,image.file).length) throw new Error('Aparecieron referencias. Cancelado.');
    const edit=new vscode.WorkspaceEdit();
    edit.deleteFile(vscode.Uri.file(full),{useTrash:true});
    if (!await vscode.workspace.applyEdit(edit)) throw new Error('No se pudo eliminar la imagen.');
    tree.refresh();
  }

  async function poll() {
    if (!(vscode.debug.sessions||[]).some(s=>s.type==='dart'&&s.name==='Muondia')) {
      tree.setObserved(null);
    } else {
      tree.setObserved(await observeDevice(root));
    }
    tree.pollFiles();
  }
  let polling=false;
  const tick=async()=>{
    if (polling) return;
    polling=true;
    try { await poll(); } finally { polling=false; }
  };

  context.subscriptions.push(tree,output,
    vscode.window.registerTreeDataProvider('muondia.visual',tree.provider),
    vscode.commands.registerCommand('muondia.visual.refresh',safe(async()=>{
      tree.refresh(); await tick();
    })),
    vscode.commands.registerCommand('muondia.visual.openState',safe(async node=>{
      if(node?.kind!=='state')return;
      await preview(node.screen.id,node.state.id);
      await tick(); // Solo marca el estado cuando Android lo confirme.
    })),
    vscode.commands.registerCommand('muondia.visual.mode',safe(async mode=>{
      if(mode==='preview'){await preview('auth','inicio');await tick();return;}
      if(mode!=='real')return;
      if(!catalogRealReady(root)){
        vscode.window.showInformationMessage(
          'Recorrido real no disponible: falta conectar el Firebase independiente de Muondia.');
        return;
      }
      const yes=await vscode.window.showWarningMessage(
        '¿Abrir el recorrido real de Muondia?',
        {modal:true,detail:'Los servicios reales pueden realizar llamadas a IA.'},
        'Abrir recorrido real');
      if(yes==='Abrir recorrido real'){
        await android(root,'shell','am','start','-n',APP+'/.MainActivity',
          '-a',APP+'.DEV_OPEN_REAL_FLOW','-f','0x20000000');
        await tick();
      }
    })),
    vscode.commands.registerCommand('muondia.visual.hide',safe(toggle)),
    vscode.commands.registerCommand('muondia.visual.show',safe(toggle)),
    vscode.commands.registerCommand('muondia.visual.replace',safe(replace)),
    vscode.commands.registerCommand('muondia.visual.rename',safe(rename)),
    vscode.commands.registerCommand('muondia.visual.delete',safe(remove)),
    vscode.commands.registerCommand('muondia.visual.find',safe(async()=>{
      const options=readCatalog(root).flatMap(screen=>screen.states.map(state=>({
        label:screen.label+' / '+state.label,description:screen.group,
        screen:screen.id,state:state.id
      })));
      const selection=await vscode.window.showQuickPick(options,
        {placeHolder:'Buscar pantalla de Muondia'});
      if(selection){await preview(selection.screen,selection.state);await tick();}
    }))
  );
  const watchers=[
    'lib/development/experiences.json','lib/development/visual_layers.dart',
    'assets/**/*','lib/**/*.dart'
  ];
  for(const pattern of watchers){
    const watcher=vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(folder,pattern));
    context.subscriptions.push(watcher,
      watcher.onDidCreate(tree.refresh),
      watcher.onDidChange(tree.refresh),
      watcher.onDidDelete(tree.refresh));
  }
  context.subscriptions.push(vscode.debug.onDidStartDebugSession(tick),
    vscode.debug.onDidTerminateDebugSession(tick));
  const timer=setInterval(()=>void tick().catch(e=>
    output.appendLine('Sondeo visual: '+String(e))),5000);
  context.subscriptions.push({dispose:()=>clearInterval(timer)});
  void tick().catch(e=>output.appendLine(String(e)));
}

module.exports={activate,readCatalog,visible,createTree,scanImages,imageReferences,
  observeDevice,inside};
