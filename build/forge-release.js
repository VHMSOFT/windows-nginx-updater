'use strict';
// Creates a Forgejo (Gitea-API) release for tag v$VER at $SHA and uploads the built zip asset.
// Uses only Node built-ins (https, fs) so the CI runner needs no zip/jq/curl - just git + node.
// Inputs via env: FORGE_API (…/api/v1/repos/<owner>/<repo>), FORGE_TOKEN, VER, SHA.
// Reads release notes from ./release-notes.txt and the asset from ./dist/windows-nginx-updater-$VER.zip.
const fs = require('fs');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const api = process.env.FORGE_API;
const token = process.env.FORGE_TOKEN;
const ver = process.env.VER;
const sha = process.env.SHA;
if (!api || !token || !ver || !sha) {
  console.error('Missing required env: FORGE_API, FORGE_TOKEN, VER, SHA.');
  process.exit(1);
}

const name = `windows-nginx-updater-${ver}.zip`;
const zipPath = `dist/${name}`;
const notes = fs.existsSync('release-notes.txt') ? fs.readFileSync('release-notes.txt', 'utf8') : '';

function request(method, urlStr, headers, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const lib = u.protocol === 'http:' ? http : https;
    const req = lib.request(
      { method, hostname: u.hostname, port: u.port || (u.protocol === 'http:' ? 80 : 443), path: u.pathname + u.search, headers },
      (res) => {
        const chunks = [];
        res.on('data', (d) => chunks.push(d));
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
      }
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

(async () => {
  const payload = JSON.stringify({ tag_name: `v${ver}`, target_commitish: sha, name: `v${ver}`, body: notes });
  const rel = await request('POST', `${api}/releases`, {
    'Authorization': `token ${token}`,
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload)
  }, payload);
  if (rel.status >= 300) {
    console.error('Create release failed:', rel.status, rel.body.toString());
    process.exit(1);
  }
  const id = JSON.parse(rel.body.toString()).id;

  const boundary = '----wnu' + process.pid + Date.now();
  const pre = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="attachment"; filename="${name}"\r\n` +
    'Content-Type: application/zip\r\n\r\n'
  );
  const post = Buffer.from(`\r\n--${boundary}--\r\n`);
  const bodyBuf = Buffer.concat([pre, fs.readFileSync(zipPath), post]);
  const up = await request('POST', `${api}/releases/${id}/assets?name=${encodeURIComponent(name)}`, {
    'Authorization': `token ${token}`,
    'Content-Type': `multipart/form-data; boundary=${boundary}`,
    'Content-Length': bodyBuf.length
  }, bodyBuf);
  if (up.status >= 300) {
    console.error('Asset upload failed:', up.status, up.body.toString());
    process.exit(1);
  }
  console.log(`Released v${ver} (id=${id})`);
})().catch((e) => { console.error(e); process.exit(1); });
