// Posts the apply on its pull request; see action.yml.
const fs = require('fs');
const { execSync } = require('child_process');

module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const sha = context.sha;
  // A manual run's context.sha is the default branch's head, not the
  // branch it checked out and applied; the workspace knows the latter.
  const appliedSha = execSync('git rev-parse HEAD', { cwd: process.env.GITHUB_WORKSPACE })
    .toString().trim();
  const isPush = context.eventName === 'push';
  const branch = isPush
    ? context.ref.replace('refs/heads/', '')
    : (process.env.APPLY_BRANCH || context.ref.replace('refs/heads/', ''));

  // A push to main applies a merge commit; its pull request is the one it
  // merged. A manual run applies a branch; its pull request is that branch's.
  let pulls;
  if (isPush) {
    pulls = (await github.rest.repos.listPullRequestsAssociatedWithCommit({
      owner, repo, commit_sha: sha,
    })).data;
  } else {
    pulls = (await github.rest.pulls.list({
      owner, repo, state: 'all', head: `${owner}:${branch}`, sort: 'updated', direction: 'desc',
    })).data;
  }
  if (pulls.length === 0) {
    core.notice(`No pull request found for ${sha} on ${branch}; the apply results stay in this run's log.`);
    return;
  }
  const pull = pulls[0];

  const path = process.env.APPLY_OUTPUT_FILE;
  let output = fs.existsSync(path) ? fs.readFileSync(path, 'utf8') : 'No apply output found.';
  const summaryMatch = output.match(/^(Apply complete!.*|No changes\..*)$/m);
  const maxLen = 60000;
  if (output.length > maxLen) {
    output = `...truncated...\n\n${output.slice(-maxLen)}`;
  }

  const status = process.env.APPLY_EXIT_CODE === '0' ? 'Success' : 'Failed';
  const runUrl = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const trigger = isPush ? `push to \`${branch}\`` : `manual run on \`${branch}\` by @${context.actor}`;
  const lines = [
    '### OpenTofu Apply Results',
    `**Status:** ${status}`,
  ];
  if (summaryMatch) {
    lines.push(`**Summary:** ${summaryMatch[0]}`);
  }
  lines.push(
    `**Commit:** ${appliedSha.slice(0, 7)}`,
    `**Trigger:** ${trigger}`,
    `**Run:** ${runUrl}`,
    `**Generated:** ${new Date().toUTCString()}`,
    '',
    '```hcl',
    output,
    '```',
  );
  await github.rest.issues.createComment({
    owner, repo, issue_number: pull.number, body: lines.join('\n'),
  });
};
