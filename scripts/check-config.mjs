import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const read = (file) => readFile(new URL(`../${file}`, import.meta.url), 'utf8');
const config = JSON.parse(await read('capacitor.config.json'));
assert.equal(config.appId, 'net.arkpedia.mobile');
assert.equal(config.server.url, 'https://www.arkpedia.net');
assert.equal(config.server.cleartext, false);
assert.equal(config.android.allowMixedContent, false);
assert.equal(config.android.webContentsDebuggingEnabled, false);
assert.ok(!config.server.allowNavigation?.length, 'Keep external origins out of the native bridge');
await read(`${config.webDir}/index.html`);
const fallback = await read(`${config.webDir}/${config.server.errorPath}`);
assert.ok(fallback.includes(`href="${config.server.url}"`), 'Retry must target production');
const android = await read('android/app/build.gradle');
assert.ok(android.includes(`applicationId "${config.appId}"`));
const ios = await read('ios/App/App.xcodeproj/project.pbxproj');
assert.ok(ios.includes(`PRODUCT_BUNDLE_IDENTIFIER = ${config.appId};`));
console.log('Production origin, navigation restrictions, fallback, and native identifiers verified.');
