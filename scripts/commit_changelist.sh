#!/bin/sh
set -eu

repo="."
workspace=""
selector=""
dry_run=0
no_verify=0
message_count=0
msg_file=""
paths_file=""
index_dir=""

cleanup() {
    [ -n "$msg_file" ] && [ -f "$msg_file" ] && rm -f "$msg_file"
    [ -n "$paths_file" ] && [ -f "$paths_file" ] && rm -f "$paths_file"
    [ -n "$index_dir" ] && [ -d "$index_dir" ] && rm -rf "$index_dir"
}
trap cleanup EXIT INT TERM

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

need_value() {
    [ $# -ge 2 ] || die "Missing value for $1"
}

real_index_matches_worktree() {
    set +e
    git -C "$repo_root" diff --quiet -- "$@"
    diff_code=$?
    set -e
    if [ "$diff_code" -ne 0 ] && [ "$diff_code" -ne 1 ]; then
        exit "$diff_code"
    fi

    other_paths=$(git -C "$repo_root" ls-files --others --exclude-standard -- "$@")
    [ "$diff_code" -eq 0 ] && [ -z "$other_paths" ]
}

has_head() {
    git -C "$repo_root" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

msg_file=$(mktemp "${TMPDIR:-/tmp}/jetbrains-changelist-message.XXXXXX")
paths_file=$(mktemp "${TMPDIR:-/tmp}/jetbrains-changelist-paths.XXXXXX")

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            need_value "$@"
            repo=$2
            shift 2
            ;;
        --repo=*)
            repo=${1#--repo=}
            shift
            ;;
        --workspace)
            need_value "$@"
            workspace=$2
            shift 2
            ;;
        --workspace=*)
            workspace=${1#--workspace=}
            shift
            ;;
        --list)
            need_value "$@"
            selector=$2
            shift 2
            ;;
        --list=*)
            selector=${1#--list=}
            shift
            ;;
        -m|--message)
            need_value "$@"
            if [ "$message_count" -gt 0 ]; then
                printf '\n' >> "$msg_file"
            fi
            printf '%s\n' "$2" >> "$msg_file"
            message_count=$((message_count + 1))
            shift 2
            ;;
        --message=*)
            value=${1#--message=}
            if [ "$message_count" -gt 0 ]; then
                printf '\n' >> "$msg_file"
            fi
            printf '%s\n' "$value" >> "$msg_file"
            message_count=$((message_count + 1))
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --no-verify)
            no_verify=1
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage:
  commit_changelist.sh [--repo PATH] [--workspace PATH] [--list NAME_OR_ID] --dry-run
  commit_changelist.sh [--repo PATH] [--workspace PATH] [--list NAME_OR_ID] -m "message"
EOF
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

command -v git >/dev/null 2>&1 || die "git is required"
command -v perl >/dev/null 2>&1 || die "perl is required"

repo_root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "Not a Git repository: $repo"
repo_root=$(cd "$repo_root" && pwd)

if [ -z "$workspace" ]; then
    workspace=$repo_root/.idea/workspace.xml
fi
[ -f "$workspace" ] || die "Missing JetBrains workspace file: $workspace"

perl - "$workspace" "$repo_root" "$selector" "$paths_file" <<'PERL'
use strict;
use warnings;
use File::Spec;

my ($workspace, $repo, $selector, $paths_file) = @ARGV;

open my $fh, '<:raw', $workspace or die "Failed to read $workspace: $!\n";
local $/;
my $xml = <$fh>;
close $fh;

my ($component) = $xml =~ m{<component\b(?=[^>]*\bname="ChangeListManager")[^>]*>(.*?)</component>}s;
die "Missing ChangeListManager component in workspace.xml\n" unless defined $component;

sub attr {
    my ($text, $name) = @_;
    return $1 if $text =~ /\b\Q$name\E="([^"]*)"/;
    return undef;
}

sub xml_unescape {
    my ($value) = @_;
    return undef unless defined $value;
    $value =~ s/&quot;/"/g;
    $value =~ s/&apos;/'/g;
    $value =~ s/&lt;/</g;
    $value =~ s/&gt;/>/g;
    $value =~ s/&amp;/&/g;
    return $value;
}

my @lists;
while ($component =~ m{<list\b([^>]*)>}sg) {
    my $attrs = $1;
    my $body = '';
    if ($attrs =~ s{/\s*$}{}) {
        $body = '';
    } else {
        my $body_start = pos($component);
        my $body_end = index($component, '</list>', $body_start);
        die "Malformed changelist entry in workspace.xml\n" if $body_end < 0;
        $body = substr($component, $body_start, $body_end - $body_start);
        pos($component) = $body_end + length('</list>');
    }
    push @lists, {
        attrs => $attrs,
        body => $body,
        name => xml_unescape(attr($attrs, 'name')),
        id => xml_unescape(attr($attrs, 'id')),
        comment => xml_unescape(attr($attrs, 'comment')),
        default => xml_unescape(attr($attrs, 'default')),
    };
}

my $selected;
if (length $selector) {
    for my $list (@lists) {
        if ((defined $list->{name} && $list->{name} eq $selector) ||
            (defined $list->{id} && $list->{id} eq $selector)) {
            $selected = $list;
            last;
        }
    }
    if (!$selected) {
        my $available = join ', ', map { defined $_->{name} ? $_->{name} : () } @lists;
        die "Changelist not found: $selector. Available: $available\n";
    }
} else {
    for my $list (@lists) {
        if (defined $list->{default} && $list->{default} eq 'true') {
            $selected = $list;
            last;
        }
    }
    die "No default JetBrains changelist found\n" unless $selected;
}

$repo = File::Spec->canonpath($repo);
$repo =~ s{[\\/]+$}{};
my $repo_norm = $repo;
$repo_norm =~ s{\\}{/}g;

sub to_relative_path {
    my ($raw) = @_;
    $raw = xml_unescape($raw);
    my $absolute;
    if ($raw =~ /^\$PROJECT_DIR\$[\\\/]?(.*)$/) {
        $absolute = File::Spec->catfile($repo, $1);
    } elsif (File::Spec->file_name_is_absolute($raw)) {
        $absolute = $raw;
    } else {
        $absolute = File::Spec->catfile($repo, $raw);
    }
    $absolute = File::Spec->canonpath($absolute);
    my $absolute_norm = $absolute;
    $absolute_norm =~ s{\\}{/}g;
    if ($absolute_norm ne $repo_norm && index($absolute_norm, "$repo_norm/") != 0) {
        die "Changelist path is outside the repository: $absolute\n";
    }
    my $relative = $absolute_norm eq $repo_norm ? '.' : substr($absolute_norm, length($repo_norm) + 1);
    $relative =~ s{^\./}{};
    return $relative;
}

my @paths;
my %seen;
while ($selected->{body} =~ m{<change\b([^>]*)/?>}sg) {
    my $attrs = $1;
    for my $field ('afterPath', 'beforePath') {
        my $raw = attr($attrs, $field);
        next unless defined $raw && length $raw;
        my $relative = to_relative_path($raw);
        next if $seen{$relative}++;
        push @paths, $relative;
    }
}

open my $out, '>:raw', $paths_file or die "Failed to write $paths_file: $!\n";
print {$out} "$_\n" for @paths;
close $out;

my $name = defined $selected->{name} ? $selected->{name} : '';
my $id = defined $selected->{id} ? $selected->{id} : '';
my $comment = defined $selected->{comment} ? $selected->{comment} : '';
print "Changelist: $name ($id)\n";
print "Comment: $comment\n" if length $comment;
print "Path count: " . scalar(@paths) . "\n";
print "$_\n" for @paths;
PERL

path_count=$(wc -l < "$paths_file" | tr -d ' ')

set --
while IFS= read -r path; do
    [ -n "$path" ] && set -- "$@" "$path"
done < "$paths_file"

if [ "$path_count" -gt 0 ]; then
    status_output=$(git -C "$repo_root" status --short -- "$@" 2>&1 || true)
    if [ -n "$status_output" ]; then
        printf '\n%s\n%s\n' "Git status for selected paths:" "$status_output"
    fi
fi

if [ "$dry_run" -eq 1 ]; then
    exit 0
fi

if [ "$path_count" -eq 0 ]; then
    exit 2
fi

if [ "$message_count" -eq 0 ]; then
    die "Commit message is required. Pass -m/--message."
fi

if real_index_matches_worktree "$@"; then
    selected_paths_are_already_indexed=1
else
    selected_paths_are_already_indexed=0
fi

index_dir=$(mktemp -d "${TMPDIR:-/tmp}/jetbrains-changelist-index.XXXXXX")
index_file=$index_dir/index

if has_head; then
    GIT_INDEX_FILE=$index_file git -C "$repo_root" read-tree HEAD
else
    GIT_INDEX_FILE=$index_file git -C "$repo_root" read-tree --empty
fi

GIT_INDEX_FILE=$index_file git -C "$repo_root" add -A -- "$@"

set +e
GIT_INDEX_FILE=$index_file git -C "$repo_root" diff --cached --quiet -- "$@"
diff_code=$?
set -e

if [ "$diff_code" -eq 0 ]; then
    die "Selected changelist has no staged changes to commit"
fi
if [ "$diff_code" -ne 1 ]; then
    exit "$diff_code"
fi

if [ "$no_verify" -eq 1 ]; then
    GIT_INDEX_FILE=$index_file git -C "$repo_root" commit --no-verify -F "$msg_file"
else
    GIT_INDEX_FILE=$index_file git -C "$repo_root" commit -F "$msg_file"
fi

if [ "$selected_paths_are_already_indexed" -eq 0 ]; then
    git -C "$repo_root" add -A -- "$@"
fi

commit=$(git -C "$repo_root" rev-parse --short HEAD)
printf '\nCommitted: %s\n' "$commit"
