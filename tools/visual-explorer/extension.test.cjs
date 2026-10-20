'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {readCatalog, visibility, createTree} = require('./extension.js');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'muondia-explorer-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  fs.mkdirSync(path.join(root, 'lib/development'), {recursive: true});
  const catalog = {version: 1, experiences: [{
    id: 'auth', label: 'Authentication', group: 'ACCESO',
    states: [{id: 'inicio', label: 'Pantalla inicial',
      source: 'lib/app/auth/auth_entry_page.dart'}],
    assets: [{name: 'Robot', file: 'assets/auth/Robot.png', flag: 'robot'}]
  }]};
  fs.writeFileSync(path.join(root, 'lib/development/experiences.json'),
    JSON.stringify(catalog));
  fs.writeFileSync(path.join(root, 'lib/development/visual_layers.dart'),
    '  static const bool robot = true;\n');
  return {root, catalog};
}

test('Solo lee pantallas y recursos declarados por Muondia', t => {
  const {root} = fixture(t);
  assert.equal(readCatalog(root)[0].id, 'auth');
  assert.equal(readCatalog(root)[0].assets[0].file, 'assets/auth/Robot.png');
  assert.equal(visibility(root, 'robot'), true);
  fs.writeFileSync(path.join(root, 'lib/development/visual_layers.dart'),
    '  static const bool robot = false;\n');
  assert.equal(visibility(root, 'robot'), false);
});

test('Rechaza rutas ajenas y capas duplicadas', t => {
  const {root, catalog} = fixture(t);
  catalog.experiences[0].states[0].source = '../other.dart';
  fs.writeFileSync(path.join(root, 'lib/development/experiences.json'),
    JSON.stringify(catalog));
  assert.throws(() => readCatalog(root));
  catalog.experiences[0].states[0].source =
    'lib/app/auth/auth_entry_page.dart';
  catalog.experiences[0].assets.push({
    name: 'Robot duplicado', file: 'assets/auth/Robot.png', flag: 'robot'
  });
  fs.writeFileSync(path.join(root, 'lib/development/experiences.json'),
    JSON.stringify(catalog));
  assert.throws(() => readCatalog(root));
});

test('Árbol visual contiene Authentication y sus estados', t => {
  const {root} = fixture(t);
  class Emitter {
    constructor() { this.event = () => {}; }
    fire() {}
    dispose() {}
  }
  const vscode = {EventEmitter: Emitter};
  const tree = createTree(root, vscode);
  const groups = tree.provider.getChildren();
  assert.equal(groups.length, 1);
  assert.equal(groups[0].label, 'ACCESO');
  const screens = tree.provider.getChildren(groups[0]);
  assert.equal(screens[0].label, 'Authentication');
  const children = tree.provider.getChildren(screens[0]);
  assert.equal(children.length, 2);
  assert.equal(children[0].kind, 'state');
  assert.equal(children[1].kind, 'image');
  tree.dispose();
});
