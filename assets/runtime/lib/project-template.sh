# project-template.sh — sourced helper, not executable.
#
# Defines apply_project_template <project-name> <type-dir>, the single place
# that seeds a project directory with a project type's default files and keeps
# them out of the project's git history.
#
# A project type declares those files by dropping them in one of two dirs,
# mirroring the project directory structure:
#
#   <type-dir>/template/   Copied to /srv/projects/<project>/<rel>, creating
#                          parent dirs. NEVER overwrites — a file that already
#                          exists (upstream-tracked, or edited by the developer)
#                          is left alone. Mode is normalised to 0644, or 0755
#                          when the source is executable — the checked-out
#                          asset's own mode carries the repo umask, which must
#                          not leak into the project.
#
#   <type-dir>/generated/  NOT copied: these are rendered by the type's own
#                          scripts/configure.sh, which needs substitution or
#                          conditional logic. Listed here only so their relative
#                          path is known. Source path == output path.
#
# Only regular files are considered (`find -type f`): a symlink dropped in
# either dir is silently ignored, so don't reach for one.
#
# Every relative path from BOTH dirs is appended to .git/info/exclude as
# "/<rel>" when absent. Entries are per file, never directory patterns: a
# template file may live in a directory whose other contents are tracked
# upstream (Moodle's .phpstorm.meta.php/ is exactly that).
#
# Idempotent — called on both `mpd create` and `mpd configure`, so a file added
# to template/ later reaches projects that already exist.
#
# Runs as the dev user; /srv/projects is dev-owned, so no sudo is needed.

apply_project_template() {
    local project="$1" type_dir="$2"
    local project_dir="/srv/projects/${project}"
    local exclude="${project_dir}/.git/info/exclude"
    local rel src dest mode

    # Append "/<rel>" to .git/info/exclude if not already listed.
    _apply_project_template_exclude() {
        [ -d "${project_dir}/.git" ] || return 0
        mkdir -p "$(dirname "$exclude")"
        # git ships info/exclude with a trailing newline, but a hand-edited one
        # may lack it — appending then would splice onto the last entry.
        if [ -s "$exclude" ] && [ -n "$(tail -c1 "$exclude")" ]; then
            echo >> "$exclude"
        fi
        grep -qxF "/$1" "$exclude" 2>/dev/null || echo "/$1" >> "$exclude"
    }

    if [ -d "${type_dir}/template" ]; then
        while IFS= read -r rel; do
            src="${type_dir}/template/${rel}"
            dest="${project_dir}/${rel}"
            if [ ! -e "$dest" ]; then
                if [ -x "$src" ]; then mode=0755; else mode=0644; fi
                install -D -m "$mode" "$src" "$dest"
                echo "Seeded ${rel}"
            fi
            _apply_project_template_exclude "$rel"
        done < <(find "${type_dir}/template" -type f -printf '%P\n' | sort)
    fi

    if [ -d "${type_dir}/generated" ]; then
        while IFS= read -r rel; do
            _apply_project_template_exclude "$rel"
        done < <(find "${type_dir}/generated" -type f -printf '%P\n' | sort)
    fi

    unset -f _apply_project_template_exclude
}
