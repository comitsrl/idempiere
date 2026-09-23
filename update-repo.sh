#!/usr/bin/env bash
# Synchronize an iDempiere fork (origin) from the official repository (upstream).
#
# Default behavior is non-destructive:
#   - Fetches and prunes remote-tracking references.
#   - Synchronizes release-13 first, then every upstream branch.
#   - Creates missing origin branches.
#   - Fast-forwards origin branches that are behind upstream.
#   - Preserves origin branches that are ahead or diverged.
#   - Adds missing upstream tags locally and to origin.
#   - Never deletes origin-only branches.
#
# Optional environment variables:
#   PRIMARY_BRANCH=release-13   Branch synchronized first.
#   SYNC_ALL_BRANCHES=1        Set to 0 to synchronize only PRIMARY_BRANCH.
#   SYNC_TAGS=1                Set to 0 to skip tag synchronization.
#   FORCE_DIVERGED=0           Set to 1 to overwrite ahead/diverged origin
#                              branches using --force-with-lease.
#   DRY_RUN=0                  Set to 1 to preview pushes/local ref changes.
#                              Fetches are still performed.
# Command-line options:
#   --target BRANCH            Synchronize only BRANCH.
#   --apply-comit              Apply the ordered Comit customizations.
#   --dry-run                  Equivalent to DRY_RUN=1.
#   --no-push                  Update and prepare locally without pushing origin.

set -Eeuo pipefail
IFS=$'\n\t'

ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
PRIMARY_BRANCH="${PRIMARY_BRANCH:-release-13}"
SYNC_ALL_BRANCHES="${SYNC_ALL_BRANCHES:-1}"
SYNC_TAGS="${SYNC_TAGS:-1}"
FORCE_DIVERGED="${FORCE_DIVERGED:-0}"
DRY_RUN="${DRY_RUN:-0}"
APPLY_COMIT="${APPLY_COMIT:-0}"
CUSTOMIZATIONS_FILE="${CUSTOMIZATIONS_FILE:-COMIT_CUSTOMIZATIONS.conf}"
PUSH_ORIGIN="${PUSH_ORIGIN:-1}"

created=0
fast_forwarded=0
unchanged=0
preserved=0
forced=0
failed=0
tags_created=0
tags_unchanged=0
tags_conflicted=0
TEMP_REFS_ROOT=''
declare -a customization_lines=()

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --target)
                (( $# >= 2 )) || die '--target requires a branch name.'
                PRIMARY_BRANCH="$2"
                SYNC_ALL_BRANCHES=0
                shift 2
                ;;
            --apply-comit)
                APPLY_COMIT=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --no-push)
                PUSH_ORIGIN=0
                shift
                ;;
            -h|--help)
                sed -n '1,30p' "$0"
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

is_enabled() {
    [[ "${1:-0}" == "1" ]]
}

validate_flag() {
    local name="$1"
    local value="$2"
    [[ "$value" == "0" || "$value" == "1" ]] || \
        die "$name must be 0 or 1; received: $value"
}

run_local_mutation() {
    if is_enabled "$DRY_RUN"; then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

push_ref() {
    local refspec="$1"
    shift

    if ! is_enabled "$PUSH_ORIGIN"; then
        log "Skipping push to ${ORIGIN_REMOTE}: ${refspec}"
        return 0
    fi

    if is_enabled "$DRY_RUN"; then
        git push --dry-run "$@" "$ORIGIN_REMOTE" "$refspec"
    else
        git push "$@" "$ORIGIN_REMOTE" "$refspec"
    fi
}

require_safe_repository_state() {
    local marker current_branch

    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" == "$PRIMARY_BRANCH" ]] && \
       [[ -n "$(git status --porcelain=v1 --untracked-files=no)" ]]; then
        die "The checked-out ${PRIMARY_BRANCH} branch has tracked changes. Commit or stash them first."
    fi

    for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
        [[ ! -e "$(git rev-parse --git-path "$marker")" ]] || \
            die "A Git operation is in progress: $marker"
    done

    [[ ! -d "$(git rev-parse --git-path rebase-merge)" ]] || \
        die 'A rebase operation is in progress.'
    [[ ! -d "$(git rev-parse --git-path rebase-apply)" ]] || \
        die 'A rebase/am operation is in progress.'
}

sync_origin_branch() {
    local branch="$1"
    local upstream_ref="refs/remotes/${UPSTREAM_REMOTE}/${branch}"
    local origin_ref="refs/remotes/${ORIGIN_REMOTE}/${branch}"
    local destination_ref="refs/heads/${branch}"
    local upstream_sha origin_sha relation local_sha

    upstream_sha="$(git rev-parse "$upstream_ref")"

    if ! git show-ref --verify --quiet "$origin_ref"; then
        log "Creating ${ORIGIN_REMOTE}/${branch} from ${UPSTREAM_REMOTE}/${branch}"
        if push_ref "${upstream_ref}:${destination_ref}"; then
            created=$((created + 1))
        else
            warn "Could not create ${ORIGIN_REMOTE}/${branch}"
            failed=$((failed + 1))
        fi
        return
    fi

    origin_sha="$(git rev-parse "$origin_ref")"

    # Never move origin directly to upstream when the local primary branch
    # contains Comit commits based on the previous upstream tip. The local
    # branch is integrated first, then published after customizations are applied.
    if [[ "$branch" == "$PRIMARY_BRANCH" ]] && \
       git show-ref --verify --quiet "refs/heads/${branch}"; then
        local_sha="$(git rev-parse "refs/heads/${branch}")"
        if git merge-base --is-ancestor "$origin_sha" "$local_sha" && \
           ! git merge-base --is-ancestor "$local_sha" "$upstream_sha"; then
            warn "Preserved ${ORIGIN_REMOTE}/${branch}: local Comit commits require integration first"
            preserved=$((preserved + 1))
            return
        fi
    fi

    if [[ "$origin_sha" == "$upstream_sha" ]]; then
        log "Unchanged: ${branch}"
        unchanged=$((unchanged + 1))
        return
    fi

    if git merge-base --is-ancestor "$origin_sha" "$upstream_sha"; then
        log "Fast-forwarding ${ORIGIN_REMOTE}/${branch} to ${UPSTREAM_REMOTE}/${branch}"
        if push_ref "${upstream_ref}:${destination_ref}"; then
            fast_forwarded=$((fast_forwarded + 1))
        else
            warn "Could not fast-forward ${ORIGIN_REMOTE}/${branch}"
            failed=$((failed + 1))
        fi
        return
    fi

    if git merge-base --is-ancestor "$upstream_sha" "$origin_sha"; then
        relation='ahead of upstream'
    else
        relation='diverged from upstream'
    fi

    if is_enabled "$FORCE_DIVERGED"; then
        warn "FORCE_DIVERGED=1: replacing ${ORIGIN_REMOTE}/${branch}, which is ${relation}"
        if push_ref \
            "${upstream_ref}:${destination_ref}" \
            "--force-with-lease=${destination_ref}:${origin_sha}"; then
            forced=$((forced + 1))
        else
            warn "Could not force-update ${ORIGIN_REMOTE}/${branch}"
            failed=$((failed + 1))
        fi
    else
        warn "Preserved ${ORIGIN_REMOTE}/${branch}: it is ${relation}"
        preserved=$((preserved + 1))
    fi
}

sync_local_primary_branch() {
    local upstream_ref="refs/remotes/${UPSTREAM_REMOTE}/${PRIMARY_BRANCH}"
    local origin_ref="refs/remotes/${ORIGIN_REMOTE}/${PRIMARY_BRANCH}"
    local local_ref="refs/heads/${PRIMARY_BRANCH}"
    local upstream_sha local_sha current_branch tracking_ref

    upstream_sha="$(git rev-parse "$upstream_ref")"
    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

    if ! git show-ref --verify --quiet "$local_ref"; then
        log "Creating local branch ${PRIMARY_BRANCH} at ${UPSTREAM_REMOTE}/${PRIMARY_BRANCH}"
        run_local_mutation git branch "$PRIMARY_BRANCH" "$upstream_ref"
    else
        local_sha="$(git rev-parse "$local_ref")"

        if [[ "$local_sha" == "$upstream_sha" ]]; then
            log "Local ${PRIMARY_BRANCH} is unchanged"
        elif git merge-base --is-ancestor "$local_sha" "$upstream_sha"; then
            log "Fast-forwarding local ${PRIMARY_BRANCH}"
            if [[ "$current_branch" == "$PRIMARY_BRANCH" ]]; then
                run_local_mutation git merge --ff-only "$upstream_ref"
            else
                run_local_mutation git update-ref "$local_ref" "$upstream_sha" "$local_sha"
            fi
        elif is_enabled "$APPLY_COMIT" && ! is_enabled "$DRY_RUN"; then
            if [[ "$current_branch" != "$PRIMARY_BRANCH" ]]; then
                [[ -z "$(git status --porcelain=v1 --untracked-files=no)" ]] || \
                    die "Tracked changes prevent switching to ${PRIMARY_BRANCH}."
                git switch "$PRIMARY_BRANCH"
            fi
            log "Merging ${UPSTREAM_REMOTE}/${PRIMARY_BRANCH} into local ${PRIMARY_BRANCH}"
            git merge --no-edit "$upstream_ref"
        else
            warn "Local ${PRIMARY_BRANCH} is ahead or diverged; it was preserved"
        fi
    fi

    if git show-ref --verify --quiet "$origin_ref"; then
        tracking_ref="${ORIGIN_REMOTE}/${PRIMARY_BRANCH}"
    else
        tracking_ref="${UPSTREAM_REMOTE}/${PRIMARY_BRANCH}"
    fi

    log "Setting local ${PRIMARY_BRANCH} to track ${tracking_ref}"
    run_local_mutation git branch --set-upstream-to="$tracking_ref" "$PRIMARY_BRANCH"
}

cleanup_temp_refs() {
    [[ -n "$TEMP_REFS_ROOT" ]] || return 0
    git for-each-ref --format='delete %(refname)' "$TEMP_REFS_ROOT" | \
        git update-ref --stdin >/dev/null 2>&1 || true
    TEMP_REFS_ROOT=''
}

trap cleanup_temp_refs EXIT

sync_tags() {
    local temp_root="refs/update-repo/$$"
    local upstream_prefix="${temp_root}/upstream/tags/"
    local origin_prefix="${temp_root}/origin/tags/"
    local upstream_tag_ref origin_tag_ref local_tag_ref tag upstream_sha origin_sha local_sha

    TEMP_REFS_ROOT="$temp_root"
    cleanup_temp_refs
    TEMP_REFS_ROOT="$temp_root"

    log "Fetching tag references into a temporary namespace"
    git fetch --quiet --no-tags "$UPSTREAM_REMOTE" \
        "+refs/tags/*:${upstream_prefix}*"
    git fetch --quiet --no-tags "$ORIGIN_REMOTE" \
        "+refs/tags/*:${origin_prefix}*"

    while IFS= read -r upstream_tag_ref; do
        [[ -n "$upstream_tag_ref" ]] || continue

        tag="${upstream_tag_ref#"$upstream_prefix"}"
        origin_tag_ref="${origin_prefix}${tag}"
        local_tag_ref="refs/tags/${tag}"
        upstream_sha="$(git rev-parse "$upstream_tag_ref")"

        if ! git show-ref --verify --quiet "$local_tag_ref"; then
            log "Adding missing local tag: ${tag}"
            run_local_mutation git update-ref "$local_tag_ref" "$upstream_sha"
        else
            local_sha="$(git rev-parse "$local_tag_ref")"
            if [[ "$local_sha" != "$upstream_sha" ]]; then
                warn "Local tag conflict preserved: ${tag}"
            fi
        fi

        if ! git show-ref --verify --quiet "$origin_tag_ref"; then
            log "Creating missing tag on ${ORIGIN_REMOTE}: ${tag}"
            if push_ref "${upstream_tag_ref}:${local_tag_ref}"; then
                tags_created=$((tags_created + 1))
            else
                warn "Could not create tag on ${ORIGIN_REMOTE}: ${tag}"
                failed=$((failed + 1))
            fi
            continue
        fi

        origin_sha="$(git rev-parse "$origin_tag_ref")"
        if [[ "$origin_sha" == "$upstream_sha" ]]; then
            tags_unchanged=$((tags_unchanged + 1))
        else
            warn "Origin tag conflict preserved: ${tag}"
            tags_conflicted=$((tags_conflicted + 1))
        fi
    done < <(git for-each-ref --format='%(refname)' "$upstream_prefix")

    cleanup_temp_refs
}

apply_comit_customizations() {
    local name ref branches commit current_branch line

    is_enabled "$APPLY_COMIT" || return 0
    [[ -f "$CUSTOMIZATIONS_FILE" ]] || \
        die "Customization manifest not found: $CUSTOMIZATIONS_FILE"

    # Snapshot the manifest before switching branches. A new target branch
    # created from upstream does not contain the Comit manifest yet.

    if is_enabled "$DRY_RUN"; then
        log "DRY-RUN: would apply Comit customizations to ${PRIMARY_BRANCH}"
        return 0
    fi

    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" != "$PRIMARY_BRANCH" ]]; then
        [[ -z "$(git status --porcelain=v1 --untracked-files=no)" ]] || \
            die "Tracked changes prevent switching to ${PRIMARY_BRANCH}."
        log "Switching to ${PRIMARY_BRANCH} to apply Comit customizations"
        git switch "$PRIMARY_BRANCH"
    fi

    log "Fetching Comit customization tags from ${ORIGIN_REMOTE}"
    git fetch --quiet "$ORIGIN_REMOTE" \
        'refs/tags/comit/custom/*:refs/tags/comit/custom/*' || \
        warn 'Could not refresh Comit customization tags; local refs will be used.'

    for line in "${customization_lines[@]}"; do
        IFS='|' read -r name ref branches <<< "$line"
        [[ -n "${name//[[:space:]]/}" ]] || continue
        [[ "$name" == \#* ]] && continue
        [[ ",${branches}," == *",${PRIMARY_BRANCH},"* ]] || continue

        commit="$(git rev-parse "${ref}^{commit}" 2>/dev/null || true)"
        [[ -n "$commit" ]] || die "Customization ${name} not found: ${ref}"

        if git merge-base --is-ancestor "$commit" HEAD; then
            log "Already present: ${name} (${ref})"
            continue
        fi

        # A cherry-pick/rebase changes the hash, but preserves the patch.
        if git cherry HEAD "$commit" "$commit^" | grep -q '^- '; then
            log "Equivalent patch already present: ${name} (${ref})"
            continue
        fi

        log "Applying Comit customization: ${name} (${ref})"
        git cherry-pick -x "$commit" || \
            die "Conflict applying ${name}. Resolve it and run: git cherry-pick --continue"
    done
}

publish_comit_branch() {
    local local_ref origin_ref local_sha origin_sha

    is_enabled "$APPLY_COMIT" || return 0
    is_enabled "$DRY_RUN" && return 0
    is_enabled "$PUSH_ORIGIN" || return 0

    local_ref="refs/heads/${PRIMARY_BRANCH}"
    origin_ref="refs/remotes/${ORIGIN_REMOTE}/${PRIMARY_BRANCH}"
    local_sha="$(git rev-parse "$local_ref")"
    origin_sha="$(git rev-parse "$origin_ref" 2>/dev/null || true)"

    if [[ -z "$origin_sha" ]] || git merge-base --is-ancestor "$origin_sha" "$local_sha"; then
        log "Publishing integrated ${PRIMARY_BRANCH} to ${ORIGIN_REMOTE}"
        git push "$ORIGIN_REMOTE" "${local_sha}:refs/heads/${PRIMARY_BRANCH}"
    else
        die "Cannot publish ${PRIMARY_BRANCH}: origin is not an ancestor of the integrated local branch."
    fi
}

main() {
    local repo_root branch
    local -a upstream_branches=()

    parse_args "$@"

    validate_flag SYNC_ALL_BRANCHES "$SYNC_ALL_BRANCHES"
    validate_flag SYNC_TAGS "$SYNC_TAGS"
    validate_flag FORCE_DIVERGED "$FORCE_DIVERGED"
    validate_flag DRY_RUN "$DRY_RUN"
    validate_flag APPLY_COMIT "$APPLY_COMIT"
    validate_flag PUSH_ORIGIN "$PUSH_ORIGIN"

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
        die 'Run this script inside a Git working tree.'

    repo_root="$(git rev-parse --show-toplevel)"
    cd "$repo_root"

    # Capture before sync_local_primary_branch can switch to a new branch.
    if is_enabled "$APPLY_COMIT"; then
        [[ -f "$CUSTOMIZATIONS_FILE" ]] || die "Customization manifest not found: $CUSTOMIZATIONS_FILE"
        mapfile -t customization_lines < "$CUSTOMIZATIONS_FILE"
    fi

    git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1 || \
        die "Remote not found: ${ORIGIN_REMOTE}"
    git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || \
        die "Remote not found: ${UPSTREAM_REMOTE}"
    git remote get-url --push "$ORIGIN_REMOTE" >/dev/null 2>&1 || \
        die "No push URL configured for ${ORIGIN_REMOTE}"

    require_safe_repository_state

    log "Repository: ${repo_root}"
    log "Origin:     $(git remote get-url "$ORIGIN_REMOTE")"
    log "Upstream:   $(git remote get-url "$UPSTREAM_REMOTE")"
    log "Primary:    ${PRIMARY_BRANCH}"

    log "Fetching branches from ${UPSTREAM_REMOTE}"
    git fetch --prune --no-tags "$UPSTREAM_REMOTE" \
        '+refs/heads/*:refs/remotes/'"${UPSTREAM_REMOTE}"'/*'

    log "Fetching branches from ${ORIGIN_REMOTE}"
    git fetch --prune --no-tags "$ORIGIN_REMOTE" \
        '+refs/heads/*:refs/remotes/'"${ORIGIN_REMOTE}"'/*'

    git show-ref --verify --quiet \
        "refs/remotes/${UPSTREAM_REMOTE}/${PRIMARY_BRANCH}" || \
        die "Branch ${UPSTREAM_REMOTE}/${PRIMARY_BRANCH} does not exist."

    # The stable branch is always handled first.
    sync_origin_branch "$PRIMARY_BRANCH"

    if is_enabled "$SYNC_ALL_BRANCHES"; then
        mapfile -t upstream_branches < <(
            git for-each-ref \
                --format='%(refname:strip=3)' \
                "refs/remotes/${UPSTREAM_REMOTE}" | sort
        )

        for branch in "${upstream_branches[@]}"; do
            [[ "$branch" != 'HEAD' ]] || continue
            [[ "$branch" != "$PRIMARY_BRANCH" ]] || continue
            sync_origin_branch "$branch"
        done
    fi

    # Refresh origin tracking refs after successful pushes.
    git fetch --prune --no-tags "$ORIGIN_REMOTE" \
        '+refs/heads/*:refs/remotes/'"${ORIGIN_REMOTE}"'/*'

    sync_local_primary_branch

    if is_enabled "$SYNC_TAGS"; then
        sync_tags
    fi

    apply_comit_customizations
    publish_comit_branch

    # Refresh remote HEAD metadata when the server permits it.
    git remote set-head "$UPSTREAM_REMOTE" --auto >/dev/null 2>&1 || true
    git remote set-head "$ORIGIN_REMOTE" --auto >/dev/null 2>&1 || true

    printf '\nSynchronization summary\n'
    printf '  Branches created:          %d\n' "$created"
    printf '  Branches fast-forwarded:   %d\n' "$fast_forwarded"
    printf '  Branches unchanged:        %d\n' "$unchanged"
    printf '  Branches preserved:        %d\n' "$preserved"
    printf '  Branches force-updated:    %d\n' "$forced"
    printf '  Tags created on origin:    %d\n' "$tags_created"
    printf '  Tags unchanged on origin:  %d\n' "$tags_unchanged"
    printf '  Tag conflicts preserved:   %d\n' "$tags_conflicted"
    printf '  Failed operations:         %d\n' "$failed"

    if (( failed > 0 )); then
        exit 2
    fi
}

main "$@"
