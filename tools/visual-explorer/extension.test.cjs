'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {readCatalog, layerVisible, setLayerVisible, safePath} =
  require('./extension.js');

test('El explorador lee pantallas y capas sin depender de otras apps', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muondia-visual-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  fs.mkdirSync(path.join(dir, 'lib', 'development'), {recursive: true});
  const sample = {
    version: 1, experiences: [
      {id: 'auth', label: 'Authentication', group: 'ACCESO',
        states: [{id: 'inicio', source: 'lib/app/auth/auth_entry_page.dart'}],
        assets: [{name: 'Robot', file: 'assets/auth/Robot.png', flag: 'robot'}]}
    ]
  };
  fs.writeFileSync(path.join(dir, 'lib/development/experiences.json'),
    JSON.stringify(sample));
  fs.writeFileSync(path.join(dir, 'lib/development/visual_layers.dart'),
    '  static const bool robot = true;\n');
  assert.equal(readCatalog(dir).experiences[0].id, 'auth');
  assert.equal(layerVisible(dir, 'robot'), true);
  assert.equal(setLayerVisible(dir, 'robot', false), true);
  assert.equal(layerVisible(dir, 'robot'), false);
  assert.equal(setLayerVisible(dir, 'robot', false), false);
  assert.equal(setLayerVisible(dir, 'robot', true), true);
  assert.equal(layerVisible(dir, 'robot'), true);
});

test('No acepta rutas fuera del proyecto ni flags arbitrarias', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muondia-visual-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  fs.mkdirSync(path.join(dir, 'lib', 'development'), {recursive: true});
  assert.throws(() => safePath(dir, '../afuera.png'));
  assert.throws(() => setLayerVisible(dir, 'robot; delete', false));
  fs.writeFileSync(path.join(dir, 'lib/development/experiences.json'),
    JSON.stringify({version: 1, experiences: [{
      id: 'auth', label: 'Auth', group: 'ACCESO',
      states: [{id: 'inicio', source: '../another.dart'}], assets: []
    }]}));
  assert.throws(() => readCatalog(dir));
});
