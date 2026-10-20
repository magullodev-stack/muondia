'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {readCatalog, visible, createTree, scanImages, imageReferences, inside} =
  require('./extension.js');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'muondia-explorer-'));
  t.after(() => fs.rmSync(root, {recursive:true, force:true}));
  for (const dir of [
    'lib/development','lib/app/auth','assets/auth','test'
  ]) fs.mkdirSync(path.join(root,dir),{recursive:true});
  const catalog={version:1,realFlowAvailable:false,experiences:[{
    id:'auth',label:'Authentication',group:'ACCESO',
    states:[
      {id:'inicio',label:'Pantalla inicial',
        source:'lib/app/auth/auth_entry_page.dart'},
      {id:'email',label:'Acceso con email',
        source:'lib/app/auth/email_auth_page.dart'}
    ],
    assetDirectories:['assets/auth'],
    assets:[{name:'Robot',file:'assets/auth/Robot.png',flag:'robot'}]
  }]};
  fs.writeFileSync(path.join(root,'lib/development/experiences.json'),
    JSON.stringify(catalog));
  fs.writeFileSync(path.join(root,'lib/development/visual_layers.dart'),
    '  static const bool robot = true;\n');
  fs.writeFileSync(path.join(root,'assets/auth/Robot.png'),'png test');
  fs.writeFileSync(path.join(root,'lib/app/auth/auth_entry_page.dart'),
    "Image.asset('assets/auth/Robot.png');\n");
  return {root,catalog};
}

function fakeVscode() {
  class Emitter {
    constructor() { this.event=()=>{}; }
    fire() { this.fired=(this.fired||0)+1; }
    dispose() {}
  }
  class TreeItem {
    constructor(label,state) { this.label=label; this.collapsibleState=state; }
  }
  class ThemeIcon {
    constructor(id,color) { this.id=id; this.color=color; }
  }
  class ThemeColor {
    constructor(id) { this.id=id; }
  }
  return {
    EventEmitter:Emitter, TreeItem,ThemeIcon,ThemeColor,
    Uri:{file:path=>({fsPath:path})},
    TreeItemCollapsibleState:{Collapsed:1,None:0}
  };
}

test('Catálogo propio y visibilidad estática, sin tocar Flutter',t=>{
  const {root}=fixture(t);
  assert.equal(readCatalog(root)[0].id,'auth');
  assert.equal(visible(root,'robot'),true);
  fs.writeFileSync(path.join(root,'lib/development/visual_layers.dart'),
    '  static const bool robot = false;\n');
  assert.equal(visible(root,'robot'),false);
  assert.throws(()=>visible(root,'notDeclared'));
});

test('Una imagen nueva aparece sola, marcada pendiente',t=>{
  const {root}=fixture(t);
  fs.writeFileSync(path.join(root,'assets/auth/Nueva.png'),'png test');
  const files=readCatalog(root)[0].assets;
  assert.equal(files.length,2);
  assert.equal(files.find(x=>x.file==='assets/auth/Nueva.png').flag,null);
  assert.equal(scanImages(root,'assets/auth').length,2);
});

test('Árbol único: modos, Authentication, estados e imágenes sin subcarpetas',t=>{
  const {root}=fixture(t),vscode=fakeVscode();
  const tree=createTree(root,vscode);
  const top=tree.provider.getChildren();
  assert.deepEqual(top.map(x=>x.kind),['mode','mode','group']);
  const group=top[2],screen=tree.provider.getChildren(group)[0];
  assert.equal(screen.label,'Authentication');
  const children=tree.provider.getChildren(screen);
  assert.deepEqual(children.map(x=>x.kind),['state','state','image']);
  tree.setObserved({mode:'preview',experience:'auth',state:'email'});
  const groupView=tree.provider.getTreeItem(group);
  const screenView=tree.provider.getTreeItem(screen);
  const emailView=tree.provider.getTreeItem(children[1]);
  assert.equal(groupView.iconPath.id,'folder-opened');
  assert.equal(screenView.iconPath.id,'eye');
  assert.equal(emailView.description,'● ESTADO ACTIVO');
  tree.setObserved(null);
  assert.equal(tree.provider.getTreeItem(screen).description,undefined);
  tree.dispose();
});

test('Rechaza carpetas solapadas y rutas fuera del proyecto',t=>{
  const {root,catalog}=fixture(t);
  assert.throws(()=>inside(root,'../../somewhere'));
  catalog.experiences[0].assetDirectories=['assets/auth','assets/auth/sub'];
  fs.writeFileSync(path.join(root,'lib/development/experiences.json'),
    JSON.stringify(catalog));
  assert.throws(()=>readCatalog(root));
  catalog.experiences[0].assetDirectories=['assets/auth'];
  catalog.experiences[0].states[0].source='../escapes.dart';
  fs.writeFileSync(path.join(root,'lib/development/experiences.json'),
    JSON.stringify(catalog));
  assert.throws(()=>readCatalog(root));
});

test('Detecta referencias: no se puede considerar pendiente una imagen usada',t=>{
  const {root}=fixture(t);
  assert.equal(imageReferences(root,'assets/auth/Robot.png').length>0,true);
  fs.writeFileSync(path.join(root,'assets/auth/Suelta.png'),'png test');
  assert.deepEqual(imageReferences(root,'assets/auth/Suelta.png'),[]);
});

test('La revisión de archivos descubre cambios externos sin reiniciar la sesión',t=>{
  const {root}=fixture(t),vscode=fakeVscode();
  const tree=createTree(root,vscode);
  fs.writeFileSync(path.join(root,'assets/auth/Externamente.png'),'png test');
  tree.pollFiles();
  const group=tree.provider.getChildren()[2];
  const screen=tree.provider.getChildren(group)[0];
  assert.equal(tree.provider.getChildren(screen).length,4);
  tree.dispose();
});
