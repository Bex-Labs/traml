// Native browser regression with isolated HTML and synthetic library responses.
// Uses the actual dashboard head, graph renderer and loader; no Auth or database.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ROOT = path.resolve(__dirname, '..');
const BASE = 'http://127.0.0.1:5520';
const GRAPH_LIBRARY_RESPONSE = 'window.vis = {DataSet: class {clear(){} add(){} get(){return null;}}, Network: class {constructor(){window.graphCreated=(window.graphCreated||0)+1;} setData(){} destroy(){}}};';
async function launch(chromium) {
    for (const channel of ['msedge', 'chrome']) {
        try { return await chromium.launch({channel, headless:true}); } catch {}
    }
    return chromium.launch({headless:true});
}
async function main() {
    const html = fs.readFileSync(path.join(ROOT, 'dashboard.html'), 'utf8');
    const head = html.match(/<head>([\s\S]*?)<\/head>/)[1];
    assert(!/<script[^>]+src=["'][^"']*vis-network/i.test(head), 'Graph must not be a startup script.');
    assert(html.includes('import { loadInvestigationGraphLibrary } from "./js/services/investigation-graph-library.js";'));
    const start = html.indexOf('        let graphRenderGeneration = 0;');
    const end = html.indexOf('        // --- Core Auto-Save Logic ---', start);
    assert(start > 0 && end > start);
    const renderer = html.slice(start, end);
    const {chromium} = require(process.env.COREAML_TEST_PLAYWRIGHT_MODULE || path.join(ROOT, '.coreaml-test-tools/node_modules/playwright'));
    const browser = await launch(chromium);
    const context = await browser.newContext({serviceWorkers:'block'});
    let requests = 0, release;
    const fixture = `<!doctype html><html><head>${head}</head><body><div id="network-placeholder"></div><div id="network-graph-container"></div><script type="module">
        import { loadInvestigationGraphLibrary } from './js/services/investigation-graph-library.js';
        let pinnedEntities = [{id:'synthetic', name:'Synthetic entity'}], pinnedTxs = [], currentProactiveCaseId = 'Synthetic case';
        let network = null, networkNodes = null, networkEdges = null;
        ${renderer}
        window.emptyGraph = () => { pinnedEntities = []; return window.renderNetworkGraph(); };
        window.startGraph = () => { pinnedEntities = [{id:'synthetic', name:'Synthetic entity'}]; return window.renderNetworkGraph(); };
        window.fixtureReady = true;
    </script></body></html>`;
    await context.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.origin === 'https://unpkg.com' && url.pathname.includes('vis-network')) {
            requests++;
            await new Promise(resolve => { release = resolve; });
            try { return await route.fulfill({contentType:'text/javascript', body:GRAPH_LIBRARY_RESPONSE}); } catch { return; }
        }
        if (url.origin === BASE && url.pathname === '/fixture') return route.fulfill({contentType:'text/html', body:fixture});
        if (url.origin === BASE && url.pathname === '/js/services/investigation-graph-library.js') return route.fulfill({contentType:'text/javascript', body:fs.readFileSync(path.join(ROOT, url.pathname), 'utf8')});
        // Other existing assets are stubbed: this is a graph-loading regression only.
        return route.fulfill({contentType:route.request().resourceType()==='stylesheet'?'text/css':'text/javascript', body:''});
    });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    try {
        // Use native timers: this regression also exercises navigation and font readiness.
        await page.goto(BASE+'/fixture', {waitUntil:'domcontentloaded'});
        await page.waitForFunction(() => window.fixtureReady);
        assert.equal(requests, 0, 'Startup must not request the graph library.');
        console.log('PASS Actual dashboard head parses without requesting optional graph library');
        await page.evaluate(() => { window.first = window.startGraph(); window.second = window.startGraph(); });
        await page.waitForFunction(() => document.querySelector('script[src*="vis-network"]'));
        await page.waitForTimeout(50);
        assert.equal(requests, 1, 'Concurrent renders must share one load.');
        assert.equal(await page.locator('#network-graph-load-status').textContent(), 'Loading investigation graph…');
        console.log('PASS Concurrent graph renders share one pending request and show loading');
        await page.waitForFunction(() => /unavailable.*retry/.test(document.querySelector('#network-graph-load-status')?.textContent || ''), null, {timeout:15000});
        await page.evaluate(() => Promise.all([window.first, window.second]));
        assert.match(await page.locator('#network-graph-load-status').textContent(), /unavailable.*retry/);
        assert.equal(await page.evaluate(() => window.graphCreated || 0), 0);
        console.log('PASS Stalled graph load has bounded visible failure without unhandled rejection');
        release();
        // Use a fresh page so timeout cancellation cannot deliver a late script to the retry probe.
        await page.goto(BASE+'/fixture', {waitUntil:'domcontentloaded'});
        await page.waitForFunction(() => window.fixtureReady);
        await page.evaluate(() => { window.pendingGraph = window.startGraph(); });
        const deadline = Date.now() + 5000;
        while (requests < 2 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
        assert.equal(requests, 2, 'Retry graph request must start within five seconds.');
        await page.evaluate(() => window.emptyGraph());
        release();
        await page.evaluate(() => window.pendingGraph);
        assert.equal(await page.evaluate(() => window.graphCreated || 0), 0, 'Late load cannot render a cleared graph.');
        assert.deepEqual(errors, [], 'The synthetic library must execute without browser errors.');
        assert.equal(await page.evaluate(() => typeof window.vis?.Network), 'function', 'The released library must load successfully.');
        console.log('PASS Clearing graph invalidates an in-flight render');
        await page.evaluate(() => window.startGraph());
        await page.waitForFunction(() => window.graphCreated === 1);
        assert.equal(requests, 2, 'Loaded library is reused.');
        console.log('PASS Actual graph renderer uses loaded DataSet/Network APIs on explicit reopen');
        assert.deepEqual(errors, []);
        console.log('PASS No uncaught browser errors; no Auth or database requests used');
    } finally { if (release) release(); await context.close(); await browser.close(); }
}
async function contracts() {
    const vm = require('node:vm');
    // Validate the exact response served by the browser route, not a separate mock.
    const fixtureRealm = {window:{}};
    new vm.Script(GRAPH_LIBRARY_RESPONSE).runInNewContext(fixtureRealm);
    assert.equal(typeof fixtureRealm.window.vis.DataSet, 'function');
    assert.equal(typeof fixtureRealm.window.vis.Network, 'function');
    new fixtureRealm.window.vis.Network();
    assert.equal(fixtureRealm.window.graphCreated, 1);
    console.log('PASS Exact browser library response parses and constructs a graph');
    const html = fs.readFileSync(path.join(ROOT, 'dashboard.html'), 'utf8');
    assert(!/<script[^>]+src=["'][^"']*vis-network/i.test(html.match(/<head>([\s\S]*?)<\/head>/)[1]));
    const scripts = [], timers = new Map();
    let timerId = 0;
    const status = {hidden:true, textContent:'', setAttribute(){}};
    const placeholder = {style:{}};
    const container = {before(){}};
    const context = vm.createContext({
        window:{}, console,
        document:{
            createElement(tag){return tag === 'script' ? {remove(){this.removed=true;}} : status;},
            head:{appendChild(script){scripts.push(script);}},
            getElementById(id){return id === 'network-graph-container' ? container : id === 'network-placeholder' ? placeholder : status;},
            fonts:{ready:Promise.resolve()}
        },
        setTimeout(callback){const id=++timerId;timers.set(id,callback);return id;},
        clearTimeout(id){timers.delete(id);}
    });
    const source = fs.readFileSync(path.join(ROOT, 'js/services/investigation-graph-library.js'),'utf8').replace('export function ', 'function ');
    vm.runInContext(source, context);
    vm.runInContext(`let network=null,networkNodes=null,networkEdges=null,pinnedEntities=[{id:'synthetic',name:'Synthetic'}],pinnedTxs=[],currentProactiveCaseId='Synthetic';` +
        html.slice(html.indexOf('        let graphRenderGeneration = 0;'), html.indexOf('        // --- Core Auto-Save Logic ---',html.indexOf('        let graphRenderGeneration = 0;'))),context);
    assert.equal(scripts.length,0);
    console.log('PASS Actual dashboard head and loader request no graph during startup');
    const first = vm.runInContext('window.renderNetworkGraph()',context);
    const second = vm.runInContext('window.renderNetworkGraph()',context);
    assert.equal(scripts.length,1);
    assert.match(status.textContent,/Loading/);
    [...timers.values()][0]();
    await Promise.all([first,second]);
    assert.match(status.textContent,/unavailable.*retry/);
    assert(scripts[0].removed);
    assert.equal(timers.size,0);
    console.log('PASS Concurrent actual renders share load; timeout is bounded and visible');
    const failed = vm.runInContext('window.renderNetworkGraph()',context);
    assert.equal(scripts.length,2);
    scripts[1].onerror();
    await failed;
    assert.match(status.textContent,/unavailable/);
    console.log('PASS Explicit retry after timeout starts a new request; load errors stay visible');
    const late = vm.runInContext('window.renderNetworkGraph()',context);
    let created=0;
    context.window.vis={DataSet:class {clear(){} add(){} get(){}},Network:class {constructor(){created++;} setData(){} destroy(){}}};
    await vm.runInContext('pinnedEntities=[];window.renderNetworkGraph()',context);
    scripts[2].onload();
    await late;
    assert.equal(created,0);
    assert.equal(status.hidden,true);
    console.log('PASS Late successful load cannot render a cleared graph');
    await vm.runInContext("pinnedEntities=[{id:'synthetic',name:'Synthetic'}];window.renderNetworkGraph()",context);
    await Promise.resolve();
    assert.equal(created,1);
    assert.equal(scripts.length,3);
    console.log('PASS Actual renderer reuses loaded DataSet/Network on reopen');
    console.log('Contract checks use simulated DOM/library; use --browser for native verification.');
}
(async()=>{await contracts();if(process.argv.includes('--browser'))await main();})().catch(error => {console.error(error); process.exitCode=1;});
