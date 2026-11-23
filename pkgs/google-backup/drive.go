package main

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

// The Drive mirror is one rclone sync of gdrive: into a directory, plus the
// files sharing a name with another one (which rclone would back up only one
// of), fetched by ID as <stem>~N<ext>. File names are rclone's spelling
// throughout: its listings, filters and paths all use it. rclone cannot open
// a local name with ‛ (U+201B) before an ordinary character, so such files
// added on disk fail the sync until renamed.

var (
	rcloneBin   = "rclone"
	driveRemote = "gdrive:"
)

const (
	// stagedPrefix names the files fetched by ID until they are moved into
	// place; Syncthing ignores .syncthing.*.tmp.
	stagedPrefix = ".syncthing.google-backup-"
)

// copies match kept copies, -kept- and -deleted- ones, in both mirrors; they
// must agree with keptTime and deletedNames.
var copies = []string{
	"*-kept-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]*",
	"*-deleted-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*",
}

// temps are Syncthing's temporary files and rclone's partial downloads.
var temps = []string{".syncthing.*", "*.partial"}

// excludes, temps and kept copies, are never backed up, synced, hashed nor
// kept. Drive files named like them are not backed up.
var excludes = filters("--exclude", slices.Concat(copies, temps))

// filters turns patterns into rclone flags.
func filters(flag string, patterns []string) []string {
	var args []string
	for _, p := range patterns {
		args = append(args, flag, p)
	}
	return args
}

func driveCmd(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("drive", flag.ExitOnError)
	out := fs.String("out", "", "mirror directory")
	manifest := fs.String("manifest", "", "what the previous run wrote or confirmed; files changed or added on disk are kept before being overwritten or removed")
	fs.Parse(args)
	if *out == "" || *manifest == "" {
		return errors.New("drive: -out and -manifest are required")
	}
	return backupDrive(ctx, *out, *manifest)
}

func backupDrive(ctx context.Context, out, manifest string) error {
	if err := syncDrive(ctx, rcloneRemote{}, out, manifest); err != nil {
		return fmt.Errorf("drive: %w", err)
	}
	return nil
}

// rclone runs one rclone command at ERROR log level, its errors going to
// stderr, and returns its output. Cancelling ctx sends it SIGTERM.
func rclone(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, rcloneBin, append([]string{"-q"}, args...)...)
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = time.Minute
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("rclone %s: %w", args[0], err)
	}
	return out, nil
}

// file is an entry of rclone lsjson.
type file struct {
	Path    string
	ID      string
	Size    int64
	ModTime time.Time
	Hashes  struct{ SHA256 string }
}

// lsjson lists the files under the last of args recursively. A file rclone
// cannot hash has no hash; rclone logs why.
func lsjson(ctx context.Context, args ...string) ([]file, error) {
	out, err := rclone(ctx, slices.Concat([]string{"lsjson", "-R", "--files-only", "--no-mimetype"}, args)...)
	if err != nil {
		return nil, err
	}
	var fs []file
	return fs, json.Unmarshal(out, &fs)
}

// remote is Drive: what it holds, and fetching one file by ID to a local path.
type remote interface {
	list(ctx context.Context) ([]file, error)
	fetch(ctx context.Context, id, dest string) error
}

type rcloneRemote struct{}

func (rcloneRemote) list(ctx context.Context) ([]file, error) {
	return lsjson(ctx, slices.Concat([]string{"--hash", "--hash-type", "sha256"}, excludes, []string{driveRemote})...)
}

func (rcloneRemote) fetch(ctx context.Context, id, dest string) error {
	_, err := rclone(ctx, "backend", "copyid", driveRemote, id, dest)
	return err
}

// entry is the manifest record of a file the backup wrote or confirmed: its
// sha256, Google's ModTime of that version and its Drive ID ("" in
// manifests that held IDs only for numbered files).
type entry struct {
	hash string
	mod  time.Time
	id   string
}

// driveLine is "<sha256>  <RFC 3339 time>  <- or Go-quoted ID>  <name>"; IDs
// of shortcuts hold a tab.
var driveLine = regexp.MustCompile(`^([0-9a-f]{64})  (\S+)  (-|"(?:[^"\\]|\\.)*")  (.+)$`)

// readDriveManifest reads the manifest; an absent file is an empty one, a
// damaged one an error.
func readDriveManifest(path string) (map[string]entry, error) {
	m := map[string]entry{}
	return m, readLines(path, driveLine, func(g []string) error {
		mod, err := time.Parse(time.RFC3339Nano, g[2])
		if err != nil {
			return err
		}
		var id string
		if g[3] != "-" {
			if id, err = strconv.Unquote(g[3]); err != nil || id == "" {
				return errors.New("bad ID")
			}
		}
		if _, dup := m[g[4]]; dup {
			return errors.New("duplicate entry")
		}
		m[g[4]] = entry{g[1], mod, id}
		return nil
	})
}

func writeDriveManifest(path string, m map[string]entry) error {
	return writeLines(path, m, func(name string, e entry) string {
		return e.hash + "  " + e.mod.UTC().Format(time.RFC3339Nano) + "  " + quoted(e.id) + "  " + name
	})
}

// target is the Drive file a local name mirrors; byID ones are numbered
// members of a duplicate-name group.
type target struct {
	file
	byID bool
}

// numbered is the name of member n of the group of files named name.
func numbered(name string, n int) string {
	stem, ext := splitExt(name)
	return stem + "~" + strconv.Itoa(n) + ext
}

// number maps each local name to the Drive file it mirrors and returns the
// names held by several files. Each of those gets <stem>~N<ext>: the N it
// had in was, else the lowest N whose name is free.
func number(files []file, was map[string]entry) (targets map[string]target, group map[string]bool) {
	byPath := map[string][]file{}
	for _, f := range files {
		byPath[f.Path] = append(byPath[f.Path], f)
	}
	targets, group = map[string]target{}, map[string]bool{}
	for p, fs := range byPath {
		if len(fs) == 1 {
			targets[p] = target{fs[0], false}
		} else {
			group[p] = true
		}
	}
	free := func(name string) bool {
		_, real := byPath[name]
		_, taken := targets[name]
		return !real && !taken
	}
	names := idNames(was, func(e entry) string { return e.id })
	for _, p := range slices.Sorted(maps.Keys(group)) {
		var fresh []file
		for _, f := range byPath[p] {
			i := slices.IndexFunc(names[f.ID], func(n string) bool { return isNumbered(n, p) && free(n) })
			if i < 0 {
				fresh = append(fresh, f)
			} else {
				targets[names[f.ID][i]] = target{f, true}
			}
		}
		slices.SortFunc(fresh, func(a, b file) int { return strings.Compare(a.ID, b.ID) })
		n := 1
		for _, f := range fresh {
			for !free(numbered(p, n)) {
				n++
			}
			targets[numbered(p, n)] = target{f, true}
		}
	}
	return targets, group
}

// idNames maps the Drive IDs of the files in m to their local names; a file
// shared along several paths has several.
func idNames[V any](m map[string]V, id func(V) string) map[string][]string {
	names := map[string][]string{}
	for _, name := range slices.Sorted(maps.Keys(m)) {
		if id := id(m[name]); id != "" {
			names[id] = append(names[id], name)
		}
	}
	return names
}

// isNumbered reports whether name is numbered(p, n) for some n.
func isNumbered(name, p string) bool {
	stem, ext := splitExt(p)
	digits, ok := strings.CutPrefix(name, stem+"~")
	digits, ok2 := strings.CutSuffix(digits, ext)
	n, err := strconv.Atoi(digits)
	return ok && ok2 && err == nil && n > 0 && numbered(p, n) == name
}

// globEscape makes name an rclone filter pattern matching only itself.
// rclone trims whitespace off patterns, so that goes in brackets.
func globEscape(name string) string {
	var b strings.Builder
	b.WriteByte('/')
	for _, r := range name {
		switch {
		case unicode.IsSpace(r):
			b.WriteString("[" + string(r) + "]")
		case strings.ContainsRune(`\*?[]{}`, r):
			b.WriteByte('\\')
			fallthrough
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// driveRun is one run of syncDrive.
type driveRun struct {
	dir     string
	remote  remote
	suffix  string           // "-kept-<time>" of this run
	was     map[string]entry // the previous manifest, under the current names
	pre     map[string]file  // local files at the start, less those moved aside
	targets map[string]target
	names   map[string][]string // names of the targets, by Drive ID
	group   map[string]bool     // names held by several Drive files
	wrote   map[string]string   // hash of each file fetched by ID, by name
	hist    *history
	checked bool // whether finish listed the mirror

	added, updated, renamed, removed, failed, kept, deleted int
}

// local lists the files under dir (or only those matching rules) by name,
// with their hashes.
func (d *driveRun) local(ctx context.Context, rules ...string) (map[string]file, error) {
	fs, err := lsjson(ctx, slices.Concat([]string{"--hash", "--hash-type", "sha256"}, rules, []string{d.dir})...)
	m := map[string]file{}
	for _, f := range fs {
		m[f.Path] = f
	}
	return m, err
}

// path is name in rclone's spelling of a local path.
func (d *driveRun) path(name string) string {
	return d.dir + "/" + name
}

// move renames from to to; whatever to held is first moved to its kept name,
// tagged with tag. Without --checksum, rclone takes a file of the same size
// and mtime for identical and just deletes from.
func (d *driveRun) move(ctx context.Context, from, to, tag string) error {
	_, err := rclone(ctx, "moveto", "--checksum", "--suffix", d.suffix+tag, "--suffix-keep-extension", d.path(from), d.path(to))
	return err
}

// moveNew renames from to the first of names that does not exist, and
// returns that name, or "" if it renamed nothing.
func (d *driveRun) moveNew(ctx context.Context, from string, names ...string) (string, error) {
	for _, to := range names {
		if _, err := rclone(ctx, "moveto", "--ignore-existing", d.path(from), d.path(to)); err != nil {
			return "", err
		}
		left, err := d.local(ctx, "--include", globEscape(from))
		if err != nil {
			return "", err
		}
		if len(left) == 0 {
			return to, nil
		}
	}
	return "", nil
}

// rclone overwrites a file already at a kept name, so each step of a run tags
// the copies it makes, and moves a name aside at most once: moveAside none,
// rename renameTag, rclone sync and fetch (disjoint names) syncTag.
const (
	renameTag = "-2"
	syncTag   = "-sync"
)

// at is the time in the names of this run's kept copies.
func (d *driveRun) at() string {
	return strings.TrimPrefix(d.suffix, "-kept-")
}

func (d *driveRun) moveAside(ctx context.Context, name string) error {
	delete(d.pre, name)
	return d.move(ctx, name, keptName(name, d.suffix), "")
}

// syncDrive mirrors Drive into dir, keeping local changes as syncDir does.
// Once the mirror is touched, the manifest is rewritten even after a failure.
func syncDrive(ctx context.Context, r remote, dir, manifest string) (err error) {
	hist := openHistory(manifest, "drive")
	defer func() { err = errors.Join(err, hist.close(ctx, err)) }()
	was, err := readDriveManifest(manifest)
	if err != nil {
		return err
	}
	files, err := r.list(ctx)
	if err != nil {
		return fmt.Errorf("listing Drive: %w", err)
	}
	var size int64
	sizeless := 0
	for _, f := range files {
		if f.Size < 0 {
			sizeless++
		} else {
			size += f.Size
		}
	}
	fmt.Fprintf(os.Stderr, "drive: logged in; %d files shared with the backup account, %d bytes + %d of unknown size\n", len(files), size, sizeless)
	// Left over by a killed run.
	staged, _ := filepath.Glob(filepath.Join(dir, stagedPrefix+"*.tmp"))
	for _, s := range staged {
		if err := os.Remove(s); err != nil {
			return err
		}
	}
	d := &driveRun{dir: dir, remote: r, suffix: "-kept-" + now().Format(keptTime), was: was, wrote: map[string]string{}, hist: hist}
	hist.totals = func() tally { return append(d.done(), count{"kept", d.kept}, count{"deleted", d.deleted}) }
	if d.pre, err = d.local(ctx, excludes...); err != nil {
		return err
	}
	// An empty listing would make every file look deleted in Google.
	if len(files) == 0 && len(d.pre) > 0 {
		return fmt.Errorf("nothing is shared with the backup account; keeping %s", dir)
	}
	d.targets, d.group = number(files, was)
	d.names = idNames(d.targets, func(t target) string { return t.ID })
	err = d.mirror(ctx)
	return errors.Join(err, d.finish(context.WithoutCancel(ctx), manifest))
}

// mirror moves aside what changed on disk, follows renames, syncs and
// fetches the numbered files.
func (d *driveRun) mirror(ctx context.Context) error {
	// rclone sync leaves the numbered names and those they replace alone.
	var skip []string
	for name, t := range d.targets {
		if t.byID {
			skip = append(skip, "--exclude", globEscape(name))
		}
	}
	for p := range d.group {
		skip = append(skip, "--exclude", globEscape(p))
	}
	// A file is moved aside if it differs from its manifest entry, else from
	// Google's sha256; one with neither is left to rclone sync and fetch, which
	// move it aside if they replace it.
	for _, name := range slices.Sorted(maps.Keys(d.pre)) {
		t, tgt := d.targets[name]
		if want := cmp.Or(d.was[name].hash, t.Hashes.SHA256); tgt && want != "" && want != d.pre[name].Hashes.SHA256 {
			if err := d.moveAside(ctx, name); err != nil {
				return err
			}
		}
	}
	renameErr := d.rename(ctx)
	if ctx.Err() != nil {
		return renameErr
	}
	// What is left under a group's plain name is retired like a file
	// rclone sync deletes.
	for p := range d.group {
		if _, ok := d.pre[p]; ok {
			if err := d.moveAside(ctx, p); err != nil {
				return err
			}
		}
	}
	_, err := rclone(ctx, slices.Concat([]string{"sync", "--retries", "1", "--suffix", d.suffix + syncTag, "--suffix-keep-extension"},
		excludes, skip, []string{driveRemote, d.dir})...)
	return errors.Join(renameErr, err, d.fetch(ctx))
}

// rename moves each unchanged file whose name is not a target of its Drive ID
// to a free name that is, without fetching it: Google renamed or moved it,
// or its duplicate-name group grew or shrank. A move can free a name for the
// next one; a name held by a file with no entry is free, as move keeps that
// file. A file whose move fails is left to rclone sync and fetch.
func (d *driveRun) rename(ctx context.Context) error {
	var errs []error
	failed := map[string]bool{}
	for moved := true; moved; {
		moved = false
		for _, from := range slices.Sorted(maps.Keys(d.pre)) {
			if ctx.Err() != nil {
				return errors.Join(append(errs, ctx.Err())...)
			}
			e := d.was[from]
			if failed[from] || d.targets[from].ID == e.id || e.hash != d.pre[from].Hashes.SHA256 {
				continue
			}
			i := slices.IndexFunc(d.names[e.id], func(n string) bool { _, busy := d.pre[n]; _, listed := d.was[n]; return !busy || !listed })
			if i < 0 {
				continue
			}
			to := d.names[e.id][i]
			if err := d.move(ctx, from, to, renameTag); err != nil {
				errs = append(errs, err)
				failed[from] = true
				// rclone may have failed after moving the file.
				if left, err := d.local(context.WithoutCancel(ctx), "--include", globEscape(from)); err != nil || len(left) > 0 {
					continue
				}
			}
			d.pre[to], d.was[to] = d.pre[from], e
			delete(d.pre, from)
			delete(d.was, from)
			d.hist.add(&d.renamed, "renamed", e.id, e.hash, from, to)
			moved = true
		}
	}
	return errors.Join(errs...)
}

// fetch puts each numbered file that Google changed since the manifest (or
// that is missing or was moved aside) in place via a staged copy.
func (d *driveRun) fetch(ctx context.Context) error {
	var errs []error
	for i, name := range slices.Sorted(maps.Keys(d.targets)) {
		t := d.targets[name]
		e, ok := d.was[name]
		if !t.byID || ok && e.id == t.ID && e.mod.Equal(t.ModTime) && e.hash == d.pre[name].Hashes.SHA256 {
			continue
		}
		if ctx.Err() != nil {
			return errors.Join(append(errs, ctx.Err())...)
		}
		staged := stagedPrefix + strconv.Itoa(i) + ".tmp"
		if err := d.remote.fetch(ctx, t.ID, d.path(staged)); err != nil {
			errs = append(errs, err)
			continue
		}
		h, err := sha256File(d.path(staged))
		if err == nil {
			err = d.move(ctx, staged, name, syncTag)
		}
		if err != nil {
			errs = append(errs, err)
			continue
		}
		d.wrote[name] = h
	}
	return errors.Join(errs...)
}

// finish sorts out this run's kept copies, writes the manifest and logs what
// happened.
func (d *driveRun) finish(ctx context.Context, manifest string) error {
	post, err := d.local(ctx, excludes...)
	if err != nil {
		return err
	}
	d.checked = true
	// Google's ModTime now, for files Google changed during the run.
	latest := map[string]time.Time{}
	if files, err := d.remote.list(ctx); err == nil {
		for _, f := range files {
			latest[f.Path] = f.ModTime
		}
	}
	current := func(name string, mod time.Time) bool {
		return mod.Equal(d.targets[name].ModTime) || mod.Equal(latest[name]) && !d.group[name]
	}
	err = d.sortKept(ctx, post, current)
	if d.kept == 0 {
		fmt.Fprintln(os.Stderr, "drive: 0 files changed on disk since the last run")
	} else {
		fmt.Fprintf(os.Stderr, "drive: %d files changed on disk since the last run, kept as *%s*\n", d.kept, d.suffix)
	}
	if d.deleted > 0 {
		fmt.Fprintf(os.Stderr, "drive: %d deleted in Google, kept as *-deleted-%s*\n", d.deleted, d.at()[:len(keptDate)])
	}
	next := map[string]entry{}
	for name, p := range post {
		h := p.Hashes.SHA256
		t, tgt := d.targets[name]
		b, had := d.pre[name]
		e, known := d.was[name]
		switch {
		case h == "":
		// Written by this run, or at Google's ModTime and, with no entry,
		// Google's sha256 if it has one.
		case tgt && (t.byID && d.wrote[name] == h || !t.byID && current(name, p.ModTime) && (known || cmp.Or(t.Hashes.SHA256, h) == h)):
			mod := p.ModTime
			if t.byID {
				mod = t.ModTime
			}
			next[name] = entry{h, mod, t.ID}
			if !had {
				d.hist.add(&d.added, "new", t.ID, h, name)
			} else if b.Hashes.SHA256 != h {
				d.hist.add(&d.updated, "updated", t.ID, h, name)
			}
		case had && b.Hashes.SHA256 == h && known:
			if tgt && !t.byID {
				e.mod, e.id = p.ModTime, t.ID
			}
			next[name] = e
		}
	}
	numberedFiles := 0
	for name, t := range d.targets {
		if e, ok := next[name]; !ok || !current(name, e.mod) {
			d.hist.add(&d.failed, "failed", t.ID, "", name)
		}
		if t.byID {
			numberedFiles++
		}
	}
	fmt.Fprintf(os.Stderr, "drive: done: %s\n", d.done().format("%d %s", ", "))
	fmt.Fprintf(os.Stderr, "drive: %d duplicate-name groups, %d files numbered\n", len(d.group), numberedFiles)
	return errors.Join(err, writeDriveManifest(manifest, next))
}

// done is the totals the done line logs; files are unchanged only once
// checked.
func (d *driveRun) done() tally {
	unchanged := 0
	if d.checked {
		unchanged = len(d.targets) - d.added - d.updated - d.failed
	}
	return tally{{"new", d.added}, {"updated", d.updated}, {"renamed", d.renamed}, {"removed", d.removed},
		{"unchanged", unchanged}, {"failed", d.failed}}
}

// sortKept handles this run's kept copies: the backup's own previous version
// is renamed -deleted- once Google no longer has it, deleted once replaced
// or once Google's current version is backed up under another name, else
// moved back; the rest count as kept.
func (d *driveRun) sortKept(ctx context.Context, post map[string]file, current func(string, time.Time) bool) error {
	var rules []string
	for _, p := range temps {
		rules = append(rules, "--filter", "- "+p)
	}
	kept, err := d.local(ctx, append(rules, "--filter", "+ *"+d.suffix+"*", "--filter", "- **")...)
	if err != nil {
		return err
	}
	var errs []error
	for _, k := range slices.Sorted(maps.Keys(kept)) {
		h := kept[k].Hashes.SHA256
		stem, rest, _ := strings.Cut(k, d.suffix)
		orig := stem + strings.TrimPrefix(strings.TrimPrefix(rest, syncTag), renameTag)
		_, there := post[orig]
		_, tgt := d.targets[orig]
		e, ok := d.was[orig]
		// What a rename moved aside had no entry.
		if strings.HasPrefix(rest, renameTag) {
			e, ok = entry{}, false
		}
		keep := func() { d.hist.add(&d.kept, "kept", e.id, h, orig, k) }
		switch {
		case !ok || h == "" || e.hash != h:
			keep()
		// Gone from Google: by ID, else by path.
		case e.id != "" && d.names[e.id] == nil || e.id == "" && !tgt:
			if to, err := d.moveNew(ctx, k, deletedNames(orig, d.at())...); to != "" {
				d.hist.add(&d.deleted, "deleted", e.id, h, orig, to)
			} else {
				keep()
				errs = append(errs, err)
			}
		// Replaced by Google's newer version, or backed up under another name.
		case there && (e.id == "" || d.targets[orig].ID == e.id) || slices.ContainsFunc(d.names[e.id], func(n string) bool {
			p, ok := post[n]
			return ok && (p.Hashes.SHA256 == e.hash || d.wrote[n] == p.Hashes.SHA256 || !d.targets[n].byID && current(n, p.ModTime))
		}):
			_, err := rclone(ctx, "deletefile", d.path(k))
			if err == nil && !tgt {
				d.hist.add(&d.removed, "removed", e.id, h, orig)
			}
			errs = append(errs, err)
		default:
			// Unless a peer took the name meanwhile.
			if to, err := d.moveNew(ctx, k, orig); to == "" {
				keep()
				errs = append(errs, err)
			} else {
				f := kept[k]
				f.Path = orig
				post[orig] = f
			}
		}
	}
	return errors.Join(errs...)
}
