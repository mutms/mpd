# project-template.sh — sourced helper defining
# apply_project_template <project-name> <type-dir>: seed a project with a
# type's default files and keep them out of the project's git history.
#
#   <type-dir>/template/   Copied to /srv/projects/<project>/<rel>. Never
#                          overwrites an existing file. Mode is normalised
#                          to 0644 (0755 when executable), so the repo
#                          umask does not leak into the project.
#   <type-dir>/generated/  Not copied — the type's configure.sh renders
#                          these. Listed here only for git excludes.
#
# Only regular files count (`find -type f`); a symlink is ignored.
# Every relative path from both dirs goes into .git/info/exclude as
# "/<rel>", per file — a template file may sit in a directory whose other
# contents are tracked upstream.
#
# Idempotent — called on both `mpd init` and `mpd start`, so a file added
# to template/ later reaches existing projects.

apply_project_template() {
    local project="$1" type_dir="$2"
    local project_dir="/srv/projects/${project}"
    local exclude="${project_dir}/.git/info/exclude"
    local rel src dest mode

    # Append "/<rel>" to .git/info/exclude if not already listed.
    _apply_project_template_exclude() {
        [ -d "${project_dir}/.git" ] || return 0
        mkdir -p "$(dirname "$exclude")"
        # A hand-edited info/exclude may lack a trailing newline; appending
        # then would splice onto the last entry.
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
