const { test } = require('node:test');
const assert = require('node:assert/strict');
const cleanup = require('../.github/scripts/cleanup-releases.cjs');
const { releasesToDelete } = cleanup;

test('empty or single release requires no deletion', () => {
  assert.deepEqual(releasesToDelete([]), []);
  assert.deepEqual(releasesToDelete([{ id: 1, published_at: '2026-11-13T00:00:00Z' }]), []);
});

test('keeps newest publication regardless of API order or tag spelling; ignores drafts', () => {
  const releases = [
    { id: 1, tag_name: 'z-old', published_at: '2026-11-11T00:00:00Z' },
    { id: 4, draft: true, published_at: '2026-11-14T00:00:00Z' },
    { id: 2, tag_name: 'a-new', published_at: '2026-11-13T00:00:00Z' },
    { id: 3, published_at: '2026-11-12T00:00:00Z' },
  ];
  assert.deepEqual(releasesToDelete(releases).map(r => r.id), [3, 1]);
});

test('fetches paginated releases and deletes only older release IDs', async () => {
  const deleted = [];
  const repo = { owner: 'test', repo: 'offline' };
  const listReleases = () => {};
  await cleanup({
    context: { repo }, core: { info() {} },
    github: {
      rest: { repos: { listReleases, async deleteRelease(args) { deleted.push(args); } } },
      async paginate(endpoint, args) {
        assert.equal(endpoint, listReleases);
        assert.deepEqual(args, { ...repo, per_page: 100 });
        return [
          { id: 2, published_at: '2026-11-13T00:00:00Z' },
          { id: 1, published_at: '2026-11-12T00:00:00Z' },
        ];
      },
    },
  });
  assert.deepEqual(deleted, [{ ...repo, release_id: 1 }]);
});
