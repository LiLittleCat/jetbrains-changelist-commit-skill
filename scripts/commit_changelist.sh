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
full_paths_file=""
ranges_file=""
entries_file=""
index_dir=""

cleanup() {
    [ -n "$msg_file" ] && [ -f "$msg_file" ] && rm -f "$msg_file"
    [ -n "$paths_file" ] && [ -f "$paths_file" ] && rm -f "$paths_file"
    [ -n "$full_paths_file" ] && [ -f "$full_paths_file" ] && rm -f "$full_paths_file"
    [ -n "$ranges_file" ] && [ -f "$ranges_file" ] && rm -f "$ranges_file"
    [ -n "$entries_file" ] && [ -f "$entries_file" ] && rm -f "$entries_file"
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
full_paths_file=$(mktemp "${TMPDIR:-/tmp}/jetbrains-changelist-full-paths.XXXXXX")
ranges_file=$(mktemp "${TMPDIR:-/tmp}/jetbrains-changelist-ranges.XXXXXX")
entries_file=$(mktemp "${TMPDIR:-/tmp}/jetbrains-changelist-entries.XXXXXX")

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

perl - "$workspace" "$repo_root" "$selector" "$paths_file" "$full_paths_file" "$ranges_file" <<'PERL'
use strict;
use warnings;
use File::Spec;

my ($workspace, $repo, $selector, $paths_file, $full_paths_file, $ranges_file) = @ARGV;

open my $fh, '<:raw', $workspace or die "Failed to read $workspace: $!\n";
local $/;
my $xml = <$fh>;
close $fh;

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

my ($component) = $xml =~ m{<component\b(?=[^>]*\bname="ChangeListManager")[^>]*>(.*?)</component>}s;
die "Missing ChangeListManager component in workspace.xml\n" unless defined $component;

sub parse_lists {
    my ($text) = @_;
    my @lists;
    while ($text =~ m{<list\b([^>]*)>}sg) {
        my $attrs = $1;
        my $body = '';
        if ($attrs =~ s{/\s*$}{}) {
            $body = '';
        } else {
            my $body_start = pos($text);
            my $body_end = index($text, '</list>', $body_start);
            die "Malformed changelist entry in workspace.xml\n" if $body_end < 0;
            $body = substr($text, $body_start, $body_end - $body_start);
            pos($text) = $body_end + length('</list>');
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
    return @lists;
}

my @lists = parse_lists($component);
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

my %ranges_by_path;
my ($line_component) = $xml =~ m{<component\b(?=[^>]*\bname="LineStatusTrackerManager")[^>]*>(.*?)</component>}s;
if (defined $line_component && defined $selected->{id}) {
    while ($line_component =~ m{<file\b([^>]*)>(.*?)</file>}sg) {
        my ($attrs, $body) = ($1, $2);
        my $raw_path = attr($attrs, 'path');
        next unless defined $raw_path && length $raw_path;
        my $relative = to_relative_path($raw_path);
        next unless $seen{$relative};
        while ($body =~ m{<range\b([^>]*)/?>}sg) {
            my $range_attrs = $1;
            my $changelist = xml_unescape(attr($range_attrs, 'changelist'));
            next unless defined $changelist && $changelist eq $selected->{id};
            my @values = map {
                my $value = attr($range_attrs, $_);
                die "Invalid line range for $relative\n" unless defined $value && $value =~ /^\d+$/;
                int($value);
            } qw(start1 end1 start2 end2);
            die "Invalid line range bounds for $relative\n"
                if $values[1] < $values[0] || $values[3] < $values[2];
            push @{ $ranges_by_path{$relative} }, \@values;
        }
    }
}

open my $paths_out, '>:raw', $paths_file or die "Failed to write $paths_file: $!\n";
print {$paths_out} "$_\n" for @paths;
close $paths_out;

open my $full_out, '>:raw', $full_paths_file or die "Failed to write $full_paths_file: $!\n";
for my $path (@paths) {
    print {$full_out} "$path\n" unless exists $ranges_by_path{$path};
}
close $full_out;

open my $ranges_out, '>:raw', $ranges_file or die "Failed to write $ranges_file: $!\n";
for my $path (@paths) {
    next unless exists $ranges_by_path{$path};
    for my $range (sort { $a->[0] <=> $b->[0] || $a->[2] <=> $b->[2] } @{ $ranges_by_path{$path} }) {
        print {$ranges_out} join("\t", $path, @$range), "\n";
    }
}
close $ranges_out;

my $name = defined $selected->{name} ? $selected->{name} : '';
my $id = defined $selected->{id} ? $selected->{id} : '';
my $comment = defined $selected->{comment} ? $selected->{comment} : '';
print "Changelist: $name ($id)\n";
print "Comment: $comment\n" if length $comment;
print "Path count: " . scalar(@paths) . "\n";
print "$_\n" for @paths;
if (%ranges_by_path) {
    print "\nLine ranges:\n";
    for my $path (@paths) {
        next unless exists $ranges_by_path{$path};
        print "$path\n";
        for my $range (@{ $ranges_by_path{$path} }) {
            print "  old $range->[0]:$range->[1] -> new $range->[2]:$range->[3]\n";
        }
    }
}
PERL

path_count=$(wc -l < "$paths_file" | tr -d ' ')
full_path_count=$(wc -l < "$full_paths_file" | tr -d ' ')
range_count=$(wc -l < "$ranges_file" | tr -d ' ')

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
    printf 'No files to commit from the selected changelist. Nothing was committed.\n' >&2
    exit 2
fi

if [ "$message_count" -eq 0 ]; then
    die "Commit message is required. Pass -m/--message."
fi

set --
while IFS= read -r path; do
    [ -n "$path" ] && set -- "$@" "$path"
done < "$full_paths_file"

if [ "$full_path_count" -gt 0 ] && real_index_matches_worktree "$@"; then
    full_paths_are_already_indexed=1
else
    full_paths_are_already_indexed=0
fi

index_dir=$(mktemp -d "${TMPDIR:-/tmp}/jetbrains-changelist-index.XXXXXX")
index_file=$index_dir/index

if has_head; then
    GIT_INDEX_FILE=$index_file git -C "$repo_root" read-tree HEAD
else
    GIT_INDEX_FILE=$index_file git -C "$repo_root" read-tree --empty
fi

if [ "$full_path_count" -gt 0 ]; then
    GIT_INDEX_FILE=$index_file git -C "$repo_root" add -A -- "$@"
fi

if [ "$range_count" -gt 0 ]; then
    perl - "$repo_root" "$ranges_file" "$entries_file" "$index_file" "$index_dir" <<'PERL'
use strict;
use warnings;
use File::Spec;

my ($repo, $ranges_file, $entries_file, $index_file, $index_dir) = @ARGV;

sub git_capture {
    my (@cmd) = @_;
    open my $fh, '-|', @cmd or die "Failed to run @cmd: $!\n";
    local $/;
    my $out = <$fh>;
    my $ok = close $fh;
    return ($ok, defined $out ? $out : '');
}

sub split_lines {
    my ($data) = @_;
    my @lines = $data =~ /.*(?:\n|\z)/g;
    pop @lines if @lines && $lines[-1] eq '';
    return @lines;
}

sub worktree_path {
    my ($repo, $path) = @_;
    return File::Spec->catfile($repo, split /\//, $path);
}

sub read_file {
    my ($path) = @_;
    return '' unless -e $path;
    open my $fh, '<:raw', $path or die "Failed to read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub head_blob {
    my ($repo, $path) = @_;
    my ($exists) = git_capture('git', '-C', $repo, 'cat-file', '-e', "HEAD:$path");
    return '' unless $exists;
    my ($ok, $data) = git_capture('git', '-C', $repo, 'show', "HEAD:$path");
    die "Failed to read HEAD:$path\n" unless $ok;
    return $data;
}

sub index_mode {
    my ($repo, $path, $index_file) = @_;
    local $ENV{GIT_INDEX_FILE} = $index_file;
    my ($ok, $out) = git_capture('git', '-C', $repo, 'ls-files', '-s', '--', $path);
    die "Failed to inspect index mode for $path\n" unless $ok;
    return $1 if $out =~ /^(\d+)\s+/;
    return '100644';
}

sub apply_ranges {
    my ($base, $worktree, $ranges, $path) = @_;
    my @base_lines = split_lines($base);
    my @worktree_lines = split_lines($worktree);
    my @selected;
    my $cursor = 0;
    for my $range (sort { $a->[0] <=> $b->[0] || $a->[2] <=> $b->[2] } @$ranges) {
        my ($start1, $end1, $start2, $end2) = @$range;
        die "Overlapping line ranges for $path\n" if $start1 < $cursor;
        die "Line range is outside file bounds for $path\n"
            if $end1 > @base_lines || $end2 > @worktree_lines;
        push @selected, @base_lines[$cursor .. $start1 - 1] if $cursor < $start1;
        push @selected, @worktree_lines[$start2 .. $end2 - 1] if $start2 < $end2;
        $cursor = $end1;
    }
    push @selected, @base_lines[$cursor .. $#base_lines] if $cursor < @base_lines;
    return join '', @selected;
}

open my $ranges_fh, '<:raw', $ranges_file or die "Failed to read $ranges_file: $!\n";
my %ranges_by_path;
while (my $line = <$ranges_fh>) {
    chomp $line;
    my ($path, $start1, $end1, $start2, $end2) = split /\t/, $line;
    push @{ $ranges_by_path{$path} }, [map { int($_) } ($start1, $end1, $start2, $end2)];
}
close $ranges_fh;

open my $entries_fh, '>:raw', $entries_file or die "Failed to write $entries_file: $!\n";
my $counter = 0;
for my $path (sort keys %ranges_by_path) {
    my $content = apply_ranges(
        head_blob($repo, $path),
        read_file(worktree_path($repo, $path)),
        $ranges_by_path{$path},
        $path,
    );
    my $content_file = File::Spec->catfile($index_dir, 'partial-' . ++$counter);
    open my $content_fh, '>:raw', $content_file or die "Failed to write $content_file: $!\n";
    print {$content_fh} $content;
    close $content_fh;

    my ($hash_ok, $hash_out) = git_capture('git', '-C', $repo, 'hash-object', '-w', "--path=$path", $content_file);
    die "Failed to hash selected content for $path\n" unless $hash_ok && $hash_out =~ /([0-9a-f]{40,64})/;
    my $oid = $1;
    my $mode = index_mode($repo, $path, $index_file);
    local $ENV{GIT_INDEX_FILE} = $index_file;
    system('git', '-C', $repo, 'update-index', '--add', '--cacheinfo', $mode, $oid, $path) == 0
        or die "Failed to update temporary index for $path\n";
    print {$entries_fh} join("\t", $mode, $oid, $path), "\n";
}
close $entries_fh;
PERL
fi

set --
while IFS= read -r path; do
    [ -n "$path" ] && set -- "$@" "$path"
done < "$paths_file"

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

set --
while IFS= read -r path; do
    [ -n "$path" ] && set -- "$@" "$path"
done < "$full_paths_file"

if [ "$full_path_count" -gt 0 ] && [ "$full_paths_are_already_indexed" -eq 0 ]; then
    git -C "$repo_root" add -A -- "$@"
fi

if [ "$range_count" -gt 0 ]; then
    perl - "$repo_root" "$entries_file" <<'PERL'
use strict;
use warnings;

my ($repo, $entries_file) = @ARGV;
open my $fh, '<:raw', $entries_file or die "Failed to read $entries_file: $!\n";
while (my $line = <$fh>) {
    chomp $line;
    my ($mode, $oid, $path) = split /\t/, $line, 3;
    system('git', '-C', $repo, 'update-index', '--add', '--cacheinfo', $mode, $oid, $path) == 0
        or die "Failed to update real index for $path\n";
}
close $fh;
PERL
fi

commit=$(git -C "$repo_root" rev-parse --short HEAD)
printf '\nCommitted: %s\n' "$commit"
