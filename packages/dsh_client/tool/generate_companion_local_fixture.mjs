// Oracle: run the unchanged C303 Node store from the snapshot, not a JS port of Dart.
// Usage: node tool/generate_companion_local_fixture.mjs /absolute/path/to/companion/store.js
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const storePath = path.resolve(process.argv[2]);
const { createCompanionStore } = await import(pathToFileURL(storePath).href);
const { initialState } = await import(pathToFileURL(path.join(path.dirname(storePath), 'state.js')).href);
const storeId = '11111111-1111-4111-8111-111111111111';
const id = n => `${n.toString().padStart(8, '0')}-2222-4222-8222-222222222222`;
const memory = (n, extras = {}) => ({id: id(n), kind: 'fact', text: `已确认的合成事实 ${n}`, keywords: ['合成'], pinned: false,
  source: {kind: 'manual'}, expiresAt: null, ...extras});
const doc = at => ({v: 1, storeId, companionId: 'whale-girl', revision: 0, memoryRevision: 0, state: initialState(at), memories: []});
const scenarios = [
  {name: 'events-expiry-clock-rollback-and-no-absence-penalty', initial: doc(1000000), actions: [
    {at: 1000000, op: 'read'}, {at: 1000000, op: 'event', type: 'visit'},
    {at: 1000001, op: 'event', type: 'visit'}, {at: 1000002, op: 'event', type: 'pet'},
    {at: 1029999, op: 'event', type: 'visit'}, {at: 1030000, op: 'event', type: 'visit'},
    {at: 1030001, op: 'event', type: 'snack'}, {at: 1075000, op: 'read'}, {at: 1075001, op: 'read'},
    {at: 1075002, op: 'event', type: 'play'}, {at: 1075003, op: 'event', type: 'pet'},
    {at: 100000, op: 'event', type: 'rest'}, {at: 100001, op: 'event', type: 'pet'},
    {at: 1000000+21600000-1, op: 'event', type: 'visit'}, {at: 1000000+21600000, op: 'event', type: 'snack'},
    {at: 1000000+86400000*365, op: 'read'}, {at: 1000000+86400000*365, op: 'event', type: 'pet'},
    {at: 1000000+86400000*366, op: 'event', type: 'rest'},
  ]},
  {name: 'memory-replacement-expiry-and-clear', initial: doc(2000000), actions: [
    {at: 2000000, op: 'save', memory: memory(1, {text: '习惯用无糖茶。\n🫖 谢谢。', pinned: true,
      source: {kind: 'user-confirmed', sessionId: 's-合成', messageId: 'm-1'}, expiresAt: 2050000})},
    {at: 2000001, op: 'save', memory: memory(2, {pinned: true, expiresAt: 2010000})},
    {at: 2000002, op: 'save', memory: memory(3, {pinned: true})},
    {at: 2000003, op: 'save', memory: memory(3, {pinned: true})},
    {at: 1990000, op: 'save', memory: memory(3, {pinned: true, text: '回拨后仍是用户确认更正。'})},
    {at: 2009999, op: 'read'}, {at: 2010000, op: 'read'}, {at: 2050000, op: 'read'},
    {at: 2050001, op: 'delete', id: id(1).toUpperCase()}, {at: 2050002, op: 'delete', id: id(1)},
    {at: 2050003, op: 'clear'}, {at: 2050004, op: 'clear'},
  ]},
  {name: 'stale-cas-identity-and-cooldown-order', initial: doc(3000000), actions: [
    {at: 3000000, op: 'event', type: 'visit'},
    {at: 3000000, op: 'event', type: 'visit', revision: 0},
    {at: 3000000, op: 'save', memory: memory(4), revision: 0},
    {at: 3000000, op: 'delete', id: id(4), revision: 0},
    {at: 3000000, op: 'clear', storeId: '99999999-1111-4111-8111-111111111111'},
    {at: 3030000, op: 'event', type: 'visit', storeId: storeId.toUpperCase()},
  ]},
  {name: 'clamp-and-independent-cooldowns', initial: (() => {const d=doc(4000000);d.state.valence=0.99;d.state.energy=0.99;d.state.closeness=0.999;return d;})(), actions: [
    {at:4000000,op:'event',type:'snack'}, {at:4000000,op:'event',type:'play'}, {at:4000000,op:'event',type:'rest'},
    {at:4000000,op:'event',type:'visit'}, {at:4000000,op:'event',type:'pet'}, {at:4000001,op:'event',type:'play'},
    {at:4030000,op:'event',type:'play'}, {at:4090000,op:'read'},
  ]},
  {name: 'unicode-validation-and-trim-parity', initial: doc(5000000), actions: [
    {at:5000000,op:'save',memory:memory(1,{text:'\u0085',keywords:['\u0085'],source:{kind:'manual',sessionId:'\u0085'}})},
    {at:5000001,op:'save',memory:memory(2,{text:'\u00a0'})},
    {at:5000002,op:'save',memory:memory(2,{text:'\u180e'})},
    {at:5000003,op:'save',memory:memory(3,{text:'\ufeff'})},
    {at:5000004,op:'save',memory:memory(3,{text:'🐋'.repeat(512)})},
    {at:5000005,op:'save',memory:memory(4,{text:'🐋'.repeat(513)})},
    {at:5000006,op:'save',memory:memory(4,{text:'\ud800'})},
    {at:5000007,op:'save',memory:memory(4,{text:'保留换行\n和\t制表'})},
    {at:5000008,op:'save',memory:memory(4,{text:'拒绝\u007f删除控制符'})},
    {at:5000009,op:'save',memory:memory(4,{source:{kind:'user-confirmed',sessionId:'🐋'.repeat(64)}})},
    {at:5000010,op:'save',memory:memory(4,{source:{kind:'user-confirmed',sessionId:'🐋'.repeat(65)}})},
  ]},
];
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'companion-parity-'));
try {
  for (const scenario of scenarios) {
    const filePath = path.join(root, `${scenario.name}.json`);
    await fs.writeFile(filePath, JSON.stringify(scenario.initial));
    let at = scenario.initial.state.anchorAt;
    const store = createCompanionStore({filePath, now: () => at});
    for (const action of scenario.actions) {
      at = action.at;
      const snapshot = await store.getSnapshot();
      const version = {storeId: action.storeId ?? snapshot.storeId, expectedRevision: action.revision ?? snapshot.revision};
      let error = null;
      try {
        if (action.op === 'event') await store.event({...version, type: action.type});
        if (action.op === 'save') await store.upsertMemory({...version, memory: action.memory});
        if (action.op === 'delete') await store.deleteMemory({...version, id: action.id});
        if (action.op === 'clear') await store.clearMemories(version);
      } catch (e) { error = e.code; }
      const exported = await store.exportData();
      delete exported.capabilities; // Storage owner / supported context API intentionally differ.
      action.expected = {error, exported, stored: JSON.parse(await fs.readFile(filePath, 'utf8')),
        pinned: await store.getContext({query: '', limit: 2})};
    }
  }
  const sourceHashes = {};
  for (const name of ['state.js','schema.js','store.js']) {
    sourceHashes[name] = createHash('sha256').update(await fs.readFile(path.join(path.dirname(storePath),name))).digest('hex');
  }
  const output = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../test/fixtures/companion_local_parity.json');
  await fs.writeFile(output, JSON.stringify({schema:'c430/c303-oracle-v1', node:process.version, sourceHashes, scenarios}, null, 2)+'\n');
  console.log(JSON.stringify({output,scenarios:scenarios.length,actions:scenarios.reduce((n,s)=>n+s.actions.length,0),sourceHashes}));
} finally { await fs.rm(root, {recursive:true, force:true}); }
