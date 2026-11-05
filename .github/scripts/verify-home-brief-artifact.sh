#!/usr/bin/env bash
set -euo pipefail
artifact=${1:-home-brief-review-screenshot}
case "$artifact" in
  home-brief-review-screenshot|iphone-screenshots) ;;
  *) echo "Unexpected iPhone screenshot artifact." >&2; exit 1 ;;
esac

if [[ "${REVIEW_MODE_ONLY:-}" != true || "${GITHUB_REPOSITORY:-}" != "mattmurf77/FumbleAI" || ! "${REVIEW_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Use catalog_only=true, one numeric iOS screenshot run and no other release operation." >&2
  exit 1
fi

run=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$REVIEW_RUN_ID")
source_sha=$(jq -er --arg repo "$GITHUB_REPOSITORY" '
  select(.repository.full_name == $repo and .head_repository.full_name == $repo and
    .path == ".github/workflows/ios-build.yml" and (.event == "push" or .event == "workflow_dispatch") and
    .status == "completed" and .conclusion == "success")
  | .head_sha | select(test("^[a-f0-9]{40}$"))' <<<"$run") || {
    echo "The source must be a successful iOS build from this repository." >&2
    exit 1
  }
git merge-base --is-ancestor "$source_sha" "$GITHUB_SHA" || { echo "Source build is outside this release history." >&2; exit 1; }
git diff --quiet "$source_sha" "$GITHUB_SHA" -- HomeApp .github/workflows/ios-build.yml .github/scripts/test-iphone.sh || {
  echo "App, test or iPhone workflow differs from the source build. Run iOS build on this release." >&2
  exit 1
}

gh api "repos/$GITHUB_REPOSITORY/actions/runs/$REVIEW_RUN_ID/artifacts?name=$artifact" |
  jq -e --arg sha "$source_sha" --arg id "$REVIEW_RUN_ID" --arg name "$artifact" '
    .total_count == 1 and (.artifacts | length) == 1 and
    (.artifacts[0] | .name == $name and .expired == false and
      .size_in_bytes > 0 and .workflow_run.head_sha == $sha and (.workflow_run.id | tostring) == $id)' >/dev/null || {
    echo "The verified run needs exactly one available $artifact artifact." >&2
    exit 1
  }
echo "Verified $artifact source run $REVIEW_RUN_ID at $source_sha."
