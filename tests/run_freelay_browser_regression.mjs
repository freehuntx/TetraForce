// Two real WebAssembly instances, including a stalled receiver and host exit.
// Requires Node 22+, Chromium, Godot web export templates, and Mosquitto.
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, symlink, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temporary = await mkdtemp(join(tmpdir(), 'tetra-browser-'));
const children = [];
const clients = [];
const output = [];
async function port() {
  const socket = createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const result = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return result;
}
function start(command, args, quiet = false) {
  const child = spawn(command, args, { cwd: root, stdio: quiet ? 'ignore' : 'pipe' });
  children.push(child);
  if (!quiet) for (const stream of [child.stdout, child.stderr]) stream.on('data', data => console.log(data.toString().trimEnd()));
  child.on('error', error => console.error(error));
  return child;
}
async function cdp(target, label) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
  let sequence = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const callbacks = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) callbacks?.reject(new Error(JSON.stringify(message.error)));
      else callbacks?.resolve(message.result);
    }
    if (message.method === 'Runtime.consoleAPICalled') {
      const text = message.params.args.map(arg => arg.value ?? arg.description ?? '').join(' ');
      output.push(text);
      if (text !== 'ERROR: Buffer full! Dropping data.' && !text.includes('at: _on_message')) console.log(label + ': ' + text);
    }
    if (message.method === 'Runtime.exceptionThrown') output.push('Browser exception: ' + message.params.exceptionDetails.text);
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => (await send('Runtime.evaluate', { expression, returnByValue: true })).result?.value;
  const result = { socket, send, evaluate };
  clients.push(result);
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `
    window.tetraChannels = []; window.tetraRTC = []; window.tetraRTCEvents = [];
    const NativeRTC = window.RTCPeerConnection;
    function channel(value, origin) {
      window.tetraChannels.push(value);
      window.tetraRTCEvents.push([origin, value.label, value.readyState]);
      value.addEventListener('open', () => window.tetraRTCEvents.push(['open', value.label, value.readyState]));
      value.addEventListener('close', () => window.tetraRTCEvents.push(['close', value.label, value.readyState]));
      return value;
    }
    window.RTCPeerConnection = class extends NativeRTC {
      constructor(...args) { super(...args); window.tetraRTC.push(this); this.addEventListener('datachannel', event => { this.tetraUsed = true; channel(event.channel, 'received'); }); }
      createDataChannel(...args) { this.tetraUsed = true; return channel(super.createDataChannel(...args), 'created'); }
    };
  ` });
  return result;
}
async function waitFor(client, predicate, description, seconds = 50, previousError = '') {
  const until = Date.now() + seconds * 1000;
  let state;
  while (Date.now() < until) {
    state = await client.evaluate('window.tetraState');
    if (predicate(state)) return state;
    if (state?.error && state.error !== previousError) throw new Error(description + ': ' + state.error);
    await delay(100);
  }
  throw new Error(description + ' timed out: ' + JSON.stringify(state));
}
try {
  const web = process.env.TETRA_WEB_DIR ?? temporary;
  if (!process.env.TETRA_WEB_DIR) {
    // Official web templates cannot override the main scene on the command
    // line. Export an isolated project configuration, sharing its resources.
    const project = join(temporary, 'project');
    await mkdir(project);
    for (const entry of await readdir(root)) {
      if (!['project.godot', '.git', 'build', 'builds'].includes(entry)) await symlink(join(root, entry), join(project, entry));
    }
    const settings = (await readFile(join(root, 'project.godot'), 'utf8')).replace(/^run\/main_scene=.*$/m, 'run/main_scene="res://tests/freelay_browser_regression.tscn"');
    await writeFile(join(project, 'project.godot'), settings);
    const exporter = start(process.env.GODOT_BIN ?? 'godot', ['--headless', '--path', project, '--export-debug', 'HTML5', join(web, 'index.html')]);
    if (await new Promise(resolve => exporter.on('exit', resolve)) !== 0) throw new Error('Web export failed');
  }
  const html = await readFile(join(web, 'index.html'), 'utf8');
  const config = JSON.parse(html.match(/const GODOT_CONFIG = (\{.*\});/)[1]);
  config.args = ['--'];
  await writeFile(join(web, 'browser-test.html'), `<!doctype html><canvas id="canvas"></canvas><script src="index.js"></script><script>
    const config = ${JSON.stringify(config)};
    const query = new URLSearchParams(location.search);
    config.args.push(...[...query].map(([key, value]) => '--' + key + '=' + value));
    new Engine(config).startGame().catch(console.error);
  </script>`);
  const brokerPort = await port(), httpPort = await port(), browserPort = await port(), joinBrowserPort = await port();
  const brokerConfig = join(temporary, 'mosquitto.conf');
  await writeFile(brokerConfig, `listener ${brokerPort} 127.0.0.1\nprotocol websockets\nallow_anonymous true\npersistence false\n`);
  start(process.env.MOSQUITTO_BIN ?? 'mosquitto', ['-c', brokerConfig], true);
  start(process.env.PYTHON_BIN ?? 'python', ['-m', 'http.server', String(httpPort), '--bind', '127.0.0.1', '--directory', web], true);
  start(process.env.CHROMIUM_BIN ?? 'chromium', ['--headless', '--no-sandbox', '--disable-dev-shm-usage', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required', `--remote-debugging-port=${browserPort}`, `--user-data-dir=${join(temporary, 'profile')}`, 'about:blank'], true);
  start(process.env.CHROMIUM_BIN ?? 'chromium', ['--headless', '--no-sandbox', '--disable-dev-shm-usage', '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required', `--remote-debugging-port=${joinBrowserPort}`, `--user-data-dir=${join(temporary, 'join-profile')}`, 'about:blank'], true);
  const api = `http://127.0.0.1:${browserPort}`;
  let targets;
  for (let i = 0; i < 100; i++) {
    try { targets = await (await fetch(api + '/json/list')).json(); if (targets.length) break; } catch {}
    await delay(100);
  }
  if (!targets?.length) throw new Error('Chromium unavailable');
  const host = await cdp(targets.find(target => target.type === 'page'), 'host');
  const lobby = 'browser-' + crypto.randomUUID();
  const url = role => `http://127.0.0.1:${httpPort}/browser-test.html?` + new URLSearchParams({ role, lobby, broker: `ws://127.0.0.1:${brokerPort}/mqtt` });
  await host.send('Page.navigate', { url: url('host') });
  await waitFor(host, state => state?.map && state.started, 'Host startup');
  const joinTargets = await (await fetch(`http://127.0.0.1:${joinBrowserPort}/json/list`)).json();
  const client = await cdp(joinTargets.find(target => target.type === 'page'), 'join');
  await client.send('Page.navigate', { url: url('join') });
  await waitFor(client, state => state?.started, 'Second window admission');
  // Block this browser's game thread while the other window remains live.
  // Resuming must drain queued traffic before evaluating any host deadline.
  await client.evaluate('(() => { const until = performance.now() + 7000; while (performance.now() < until) {} })()');
  const joined = await waitFor(client, state => state?.map && state.members === 2 && state.checkpoint && state.rtc && state.marker.includes(42) && !state.migrating, 'Join after a stalled frame', 20);
  const hosting = await waitFor(host, state => state?.players === 2 && state.rtc, 'Two browser peers');
  if (joined.host !== hosting.host || joined.epoch !== hosting.epoch) throw new Error('Browser peers disagree on host');
  await client.evaluate('(() => { const until = performance.now() + 7000; while (performance.now() < until) {} })()');
  await waitFor(client, state => state?.players === 2 && state.members === 2 && state.epoch === 0 && state.rtc && !state.migrating, 'Established RTC receiver after a stalled frame', 20);
  await client.evaluate("window.tetraAction = 'bad-profile'");
  await waitFor(client, state => state?.error === 'Invalid player data.' && !state.map && !state.migrating, 'Intentional rejection uses its real reason');
  await waitFor(host, state => state?.players === 1 && state.members === 1 && state.epoch === 0 && !state.migrating, 'A rejection must not start a host election');
  await client.evaluate("window.tetraAction = 'rejoin'");
  await waitFor(client, state => state?.players === 2 && state.members === 2 && state.checkpoint && state.rtc && !state.migrating, 'Rejoin after rejection', 50, 'Invalid player data.');
  await host.evaluate("window.tetraAction = 'leave'");
  await waitFor(client, state => state?.epoch === 1 && state.players === 1 && state.map && !state.migrating && state.marker.includes(42), 'Two-window graceful handover');
  await waitFor(host, state => state?.leaving && !state.map, 'Departing browser cleanup');
  await delay(3000);
  if (!await host.evaluate("window.tetraChannels.length > 0 && window.tetraChannels.every(channel => channel.readyState === 'closed' && channel.onmessage === null) && window.tetraRTC.filter(peer => peer.tetraUsed).every(peer => peer.connectionState === 'closed')")) throw new Error('Departing browser retained live RTC channels or message callbacks');
  if (output.some(line => /SCRIPT ERROR|ERROR:|Browser exception:|Buffer full/.test(line) || (line.includes('Freelay session failed') && !line.includes('Invalid player data.')))) throw new Error('Browser runtime errors');
  console.log('Two-window browser regression passed: stalled join/RTC, shared host, checkpoint, rejection/rejoin and graceful migration.');
} catch (error) {
  console.error(error);
  for (const client of clients) console.log('Browser diagnostic: ' + JSON.stringify(await client.evaluate('({ state: window.tetraState, events: window.tetraRTCEvents, channels: window.tetraChannels?.map(channel => ({ label: channel.label, state: channel.readyState, listener: channel.onmessage !== null })), peers: window.tetraRTC?.map(peer => ({ state: peer.connectionState, used: !!peer.tetraUsed })) })')));
  console.log('Buffer error count: ' + output.filter(line => line.includes('Buffer full')).length);
  process.exitCode = 1;
} finally {
  for (const client of clients) client.socket.close();
  for (const child of children) if (child.exitCode === null) child.kill();
  await Promise.all(children.map(child => child.exitCode === null ? new Promise(resolve => child.once('exit', resolve)) : Promise.resolve()));
  await rm(temporary, { recursive: true, force: true });
}
