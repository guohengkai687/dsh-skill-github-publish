// Create a GitHub repo via API (idempotent). UTF-8 file; run with: node create-repo.mjs
// Env needed: GH_TOKEN (OAuth token), HTTPS_PROXY + NODE_USE_ENV_PROXY=1 (if behind a local proxy)
const name = process.argv[2] || process.env.GH_REPO_NAME;
const privateRepo = (process.env.GH_REPO_PRIVATE || 'false') === 'true';
const description = process.env.GH_REPO_DESC || '';

if (!name) {
  console.error('usage: GH_TOKEN=... node create-repo.mjs <repo-name>');
  process.exit(2);
}

const body = JSON.stringify({
  name,
  description,
  homepage: '',
  private: privateRepo,
  has_issues: true,
  has_wiki: false,
});

const r = await fetch('https://api.github.com/user/repos', {
  method: 'POST',
  headers: {
    Authorization: 'Bearer ' + process.env.GH_TOKEN,
    'User-Agent': 'dsh-github-publish',
    'Content-Type': 'application/json',
    'Accept': 'application/vnd.github+json',
  },
  body,
});
const j = await r.json();

if (r.status === 422 && j.errors && j.errors.some((e) => (e.message || '').includes('name already exists'))) {
  console.log('REPO_EXISTS');
  process.exit(0);
}
if (!r.ok) {
  console.error('CREATE_FAIL status=' + r.status + ' msg=' + JSON.stringify(j));
  process.exit(1);
}
console.log('REPO_CREATED ' + j.full_name + ' clone=' + j.clone_url);