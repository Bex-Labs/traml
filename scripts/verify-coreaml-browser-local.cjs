/* Local browser verification. Never loads a hosted CoreAML backend. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {randomInt} = require('node:crypto');
const root = path.resolve(__dirname, '..');
const base = 'http://127.0.0.1:5520';
const api = 'http://127.0.0.1:55321';
const output = path.join(root, '.coreaml-local', 'browser');
const roles = ['it_admin', 'head_of_compliance', 'compliance_officer', 'bank_manager',
  'branch_manager', 'teller', 'sales_rep', 'bankmanager', 'compliance_bank2', 'compliance_bank3', 'compliance_bank4'];
const makers = new Set(['branch_manager', 'teller', 'sales_rep', 'bankmanager']);
const report = { scope: 'Local browser login for 11 staff, teller onboarding and pending-account lookup', checks: [], observations: [] };
const clean = value => String(value).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[JWT removed]')
  .replace(/sb_secret_[\w-]+/g, '[secret removed]').replace(/CoreAML-Local-Only!2026/g, '[password removed]').slice(0, 700);
async function check(actor, name, action) {
  try { await action(); report.checks.push({actor, check: name, result: 'PASS'}); return true; }
  catch (error) { report.checks.push({actor, check: name, result: 'FAIL', error: clean(error.message)}); return false; }
}
async function launch(chromium) {
  const errors = [];
  for (const channel of ['msedge', 'chrome']) {
    try { return await chromium.launch({ channel, headless: !process.argv.includes('--headed') }); }
    catch (error) { errors.push(clean(error.message)); }
  }
  throw new Error('Could not launch installed Edge or Chrome. Install either browser, then rerun. ' + errors.join(' '));
}
async function main() {
  fs.mkdirSync(output, {recursive: true});
  const {chromium} = require(path.join(root, '.coreaml-test-tools', 'node_modules', 'playwright'));
  const response = await fetch(base + '/index.html', {signal: AbortSignal.timeout(10000)});
  assert.equal(response.status, 200, 'Start the local Python web server on port 5520.');
  const browser = await launch(chromium);
  try {
    for (const actor of roles) {
      const context = await browser.newContext({ viewport: {width: 1440, height: 1000} });
      const blocked = [];
      // External static assets are allowed; all other network requests stay local.
      await context.route('**/*', async route => {
        const url = new URL(route.request().url());
        const local = [base, api].includes(url.origin);
        const asset = ['cdn.jsdelivr.net', 'cdnjs.cloudflare.com', 'fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.tailwindcss.com'].includes(url.hostname)
          && ['GET', 'HEAD'].includes(route.request().method());
        // Existing dashboard graph dependency; unpkg may redirect to a versioned URL.
        const graphAsset = url.protocol === 'https:' && url.hostname === 'unpkg.com'
          && /^\/vis-network(?:@[0-9A-Za-z.+-]+)?\/standalone\/umd\/vis-network\.min\.js$/.test(url.pathname)
          && ['GET', 'HEAD'].includes(route.request().method());
        if (local || asset || graphAsset) return route.continue();
        blocked.push(url.origin + url.pathname); return route.abort('blockedbyclient');
      });
      const page = await context.newPage();
      page.setDefaultTimeout(30000);
      const dialogs = [];
      page.on('dialog', async dialog => { dialogs.push(dialog.message()); await dialog.accept(); });
      page.on('pageerror', error => report.observations.push({actor, kind: 'uncaught browser error', message: clean(error.message)}));
      try {
        const banking = makers.has(actor);
        const loggedIn = await check(actor, 'Actual login form, destination and trusted role/bank', async () => {
          await page.goto(base + (banking ? '/bank-login.html' : '/index.html'));
          const configured = await page.evaluate(async () => (await import('/js/config.js')).supabase.supabaseUrl);
          assert.equal(configured.replace(/\/$/, ''), api, 'Browser backend must be local before login.');
          await page.locator(banking ? '#teller-email' : '#email').fill(actor + '@coreaml-local.test');
          await page.locator(banking ? '#teller-password' : '#password').fill(process.env.COREAML_LOCAL_PASSWORD || 'CoreAML-Local-Only!2026');
          const destination = banking ? 'core-banking.html' : actor === 'it_admin' ? 'admin-dashboard.html' : 'dashboard.html';
          await Promise.all([page.waitForURL(base + '/' + destination), page.locator(banking ? '#teller-login-form button[type=submit]' : '#login-form button[type=submit]').click()]);
          const metadata = await page.evaluate(async () => {
            const {supabase} = await import('/js/config.js');
            const {data, error} = await supabase.auth.getSession();
            if (error || !data.session) throw new Error('No browser session');
            return data.session.user.app_metadata;
          });
          assert.equal(metadata.role, actor.startsWith('compliance_bank') ? 'compliance_officer' : actor);
          const bank = actor.match(/bank([234])$/)?.[1] || '1';
          assert.equal(metadata.tenant_id, 'a1000000-0000-4000-8000-00000000000' + bank);
          if (banking) await page.waitForFunction(() => !['...', ''].includes(document.querySelector('#ui-teller-role')?.textContent.trim() || ''));
          else await page.locator('body').waitFor({state: 'visible'});
        });
        if (loggedIn && actor === 'teller') {
          let accountNumber;
          await check(actor, 'Submit actual onboarding form and verify pending zero-balance account', async () => {
            await page.locator('#nav-onboard-tab').click();
            await page.locator('#ob-type').selectOption('RETAIL');
            await page.locator('#ob-first-name').fill('SyntheticBrowser');
            await page.locator('#ob-last-name').fill(String(Date.now()));
            // Fresh synthetic candidate on every run; never weaken BVN uniqueness.
            let syntheticBvn;
            for (let attempt = 0; attempt < 20; attempt++) {
              const candidate = String(randomInt(10000000000, 100000000000));
              const exists = await page.evaluate(async bvn => {
                const {supabase} = await import('/js/config.js');
                const {data, error} = await supabase.from('customers').select('id').eq('bvn', bvn).limit(1);
                if (error) throw new Error(error.message);
                return data.length > 0;
              }, candidate);
              if (!exists) { syntheticBvn = candidate; break; }
            }
            assert.ok(syntheticBvn, 'Could not allocate a fresh synthetic BVN');
            await page.locator('#ob-bvn').fill(syntheticBvn);
            const buffer = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=', 'base64');
            for (const id of ['#ob-id-file', '#ob-utility-file']) await page.locator(id).setInputFiles({name: 'synthetic.png', mimeType: 'image/png', buffer});
            dialogs.length = 0;
            await page.locator('#btn-submit-onboard').click();
            const until = Date.now() + 45000;
            while (!dialogs.length && Date.now() < until) await page.waitForTimeout(150);
            const match = dialogs.join('\n').match(/Application confirmed\. Account (\d{10}): PENDING/);
            assert.ok(match, 'Expected confirmed pending application; dialog: ' + clean(dialogs.join(' ')));
            accountNumber = match[1];
            const record = await page.evaluate(async number => {
              const {supabase} = await import('/js/config.js');
              const {data, error} = await supabase.from('accounts').select('status,balance').eq('account_number', number).single();
              if (error) throw new Error(error.message); return data;
            }, accountNumber);
            assert.equal(record.status, 'PENDING'); assert.equal(Number(record.balance), 0);
            report.createdAccountNumber = accountNumber;
          });
          if (accountNumber) await check(actor, 'Cash lookup labels pending account and clears posting selection', async () => {
            await page.locator('#nav-cash-tab').click();
            await page.locator('#lookup-acct').fill(accountNumber);
            await page.waitForFunction(() => document.querySelector('#cust-tier')?.textContent.includes('PENDING KYC APPROVAL'));
            assert.equal(await page.locator('#verified-account-id').inputValue(), '');
            assert.equal(await page.locator('#btn-post-tx').isDisabled(), true);
          });
          else report.checks.push({actor, check: 'Cash lookup labels pending account and clears posting selection', result: 'BLOCKED', error: 'Onboarding did not return an account number'});
        }
        await check(actor, 'No unexpected network destinations requested', async () => assert.deepEqual(blocked, []));
        await page.screenshot({path: path.join(output, actor + '.png'), fullPage: true});
      } finally { await context.close(); }
    }
  } finally { await browser.close(); }
}
main().catch(error => { report.checks.push({actor: 'runner', check: 'Browser prerequisites/execution', result: 'FAIL', error: clean(error.message)}); })
  .finally(() => {
    fs.mkdirSync(output, {recursive: true});
    report.summary = {pass: report.checks.filter(x => x.result === 'PASS').length, fail: report.checks.filter(x => x.result === 'FAIL').length, blocked: report.checks.filter(x => x.result === 'BLOCKED').length};
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(report, null, 2));
    console.table(report.checks); console.log('Summary:', report.summary);
    console.log('Report/screenshots: .coreaml-local/browser/');
    console.log('Scope excludes KYC approval, AML detection, cash posting, and complete admin workflows.');
    if (report.summary.fail || report.summary.blocked || report.observations.length) { console.log('Uncaught browser errors:', report.observations.length); process.exitCode = 1; }
  });
