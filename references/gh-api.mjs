#!/usr/bin/env node
// gh-api.mjs — small GitHub REST helper used by dsh-skill-github-publish.
//
// Cross-platform (Node 18+; WSL/Git-Bash/Windows/macOS/Linux alike). Uses the global
// fetch, which carries its own CA bundle, so it works even where a platform curl or
// PowerShell transport cannot reach api.github.com (Windows sandbox schannel being the
// classic case). A proxy is only used when Node is told about it:
//   HTTPS_PROXY=http://127.0.0.1:7890 NODE_USE_ENV_PROXY=1 node gh-api.mjs whoami
//
// Auth: GH_TOKEN or GITHUB_TOKEN in the environment. The publish scripts resolve the
// token (gh_token.txt / credential manager) and export it — never pass a token as an argument,
// it would land in `ps` output and shell history.
//
// Usage:
//   node gh-api.mjs whoami
//   node gh-api.mjs create  --name NAME [--private] [--desc "one line"]
//   node gh-api.mjs get     --repo OWNER/NAME
//   node gh-api.mjs commits --repo OWNER/NAME [--branch BRANCH]
//   node gh-api.mjs patch   --repo OWNER/NAME [--private|--public] [--name NEW] [--desc TEXT]
//   node gh-api.mjs delete  --repo OWNER/NAME      (needs the delete_repo scope on classic PATs)
//
// Scopes: publishing needs `repo` (plus `workflow` to push workflow files); `delete` additionally
// needs `delete_repo`, which most tokens lack - expect 403 and fall back to the web UI.
//
// Output is one machine-readable line per action (`USER`, `REPO_CREATED`, …) so callers can
// grep it; failures print `API_FAIL status=<n> msg=<...>` and exit 1.

const API = 'https://api.github.com';

function die(msg, code = 2) {
  console.error(msg);
  process.exit(code);
}

const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';
if (!token) die('NO_TOKEN: set GH_TOKEN (the publish scripts read it from gh_token.txt)');

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

async function api(method, path, body) {
  const r = await fetch(API + path, {
    method,
    headers: {
      Authorization: 'Bearer ' + token,
      'User-Agent': 'dsh-skill-github-publish',
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  const text = await r.text();
  if (text) { try { json = JSON.parse(text); } catch { json = { message: text }; } }
  return { status: r.status, ok: r.ok, json };
}

function fail(status, json) {
  console.error('API_FAIL status=' + status + ' msg=' + JSON.stringify(json));
  process.exit(1);
}

function needRepo(args) {
  if (!args.repo || args.repo === true) die('missing --repo OWNER/NAME');
  return args.repo;
}

const [cmd, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);

switch (cmd) {
  case 'whoami': {
    const { status, ok, json } = await api('GET', '/user');
    if (!ok) fail(status, json);
    console.log('USER ' + json.login);
    break;
  }

  case 'create': {
    if (!args.name || args.name === true) die('missing --name NAME');
    const body = {
      name: args.name,
      description: typeof args.desc === 'string' ? args.desc : '',
      homepage: '',
      private: args.private === true,
      has_issues: true,
      has_wiki: false,
    };
    const { status, ok, json } = await api('POST', '/user/repos', body);
    if (status === 422 && JSON.stringify(json).includes('already exists')) {
      console.log('REPO_EXISTS ' + args.name);
      break;
    }
    if (!ok) fail(status, json);
    console.log('REPO_CREATED ' + json.full_name + ' clone=' + json.clone_url);
    break;
  }

  case 'get': {
    const repo = needRepo(args);
    const { status, ok, json } = await api('GET', '/repos/' + repo);
    if (!ok) fail(status, json);
    console.log(
      'REPO ' + json.full_name +
      ' private=' + json.private +
      ' default_branch=' + json.default_branch +
      ' pushed_at=' + json.pushed_at
    );
    break;
  }

  case 'commits': {
    const repo = needRepo(args);
    const branch = typeof args.branch === 'string' ? args.branch : '';
    const { status, ok, json } = await api('GET', '/repos/' + repo + '/commits' + (branch ? '?sha=' + encodeURIComponent(branch) + '&per_page=1' : '?per_page=1'));
    if (!ok) fail(status, json);
    if (!Array.isArray(json) || json.length === 0) fail(status, { message: 'no commits on ' + (branch || 'default branch') });
    const c = json[0];
    console.log('HEAD ' + c.sha.slice(0, 7) + ' ' + c.commit.message.split('\n')[0]);
    break;
  }

  case 'patch': {
    const repo = needRepo(args);
    const body = {};
    if (args.private === true) body.private = true;
    if (args.public === true) body.private = false;
    if (typeof args.name === 'string') body.name = args.name;
    if (typeof args.desc === 'string') body.description = args.desc;
    if (Object.keys(body).length === 0) die('patch needs at least one of --private/--public/--name/--desc');
    const { status, ok, json } = await api('PATCH', '/repos/' + repo, body);
    if (!ok) fail(status, json);
    console.log('REPO_UPDATED ' + json.full_name + ' private=' + json.private);
    break;
  }

  case 'delete': {
    const repo = needRepo(args);
    const { status, ok, json } = await api('DELETE', '/repos/' + repo);
    if (!ok && status !== 204) fail(status, json);
    console.log('REPO_DELETED ' + repo);
    break;
  }

  default:
    die('usage: gh-api.mjs <whoami|create|get|commits|patch|delete> [options]');
}
