// Publishing and cleanup share a concurrency group; drafts may be incomplete uploads.
function releasesToDelete(releases) {
  return releases
    .filter(release => !release.draft && release.published_at)
    .sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at) || b.id - a.id)
    .slice(1);
}

async function cleanup({ github, context, core }) {
  const repo = context.repo;
  const releases = await github.paginate(github.rest.repos.listReleases, {
    ...repo, per_page: 100,
  });
  const obsolete = releasesToDelete(releases);
  core.info(`Found ${releases.length} releases; deleting ${obsolete.length} older published releases.`);
  for (const release of obsolete) {
    core.info(`Deleting release ${release.tag_name} (${release.id})`);
    await github.rest.repos.deleteRelease({ ...repo, release_id: release.id });
  }
}

module.exports = cleanup;
module.exports.releasesToDelete = releasesToDelete;
