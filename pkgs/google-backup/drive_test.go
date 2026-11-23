package main

import (
	"cmp"
	"context"
	"encoding/hex"
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testRclone = "/nix/store/sf7i6h7n7pckr2dkcfhg4qxyn2bc2p08-rclone-1.76.0/bin/rclone"

// standIn points gdrive: at a new local directory with Drive's encoding and
// returns it; tests that need rclone skip without it.
func standIn(t *testing.T) string {
	t.Helper()
	bin, err := exec.LookPath(cmp.Or(os.Getenv("RCLONE"), testRclone))
	if err != nil {
		t.Skipf("rclone 1.76 not found, set RCLONE: %v", err)
	}
	oldBin, oldRemote := rcloneBin, driveRemote
	t.Cleanup(func() { rcloneBin, driveRemote = oldBin, oldRemote })
	rcloneBin = bin
	fixedClock(t)
	t.Setenv("RCLONE_CONFIG", "/dev/null")
	t.Setenv("RCLONE_CONFIG_GDRIVE_TYPE", "local")
	src := t.TempDir()
	// Drive's encoding, with its "/" in names as rclone spells it; in the
	// connection string, so that no flag overrides it.
	driveRemote = "gdrive,encoding='Slash,InvalidUtf8':" + src
	return src
}

// fakeRemote is the stand-in plus extra files: those can share a name, and
// each file has an ID (the stand-in's own: "s" and the hex of its path).
type fakeRemote struct {
	src     string
	ids     map[string]string // IDs of stand-in files, by path
	extra   []file
	bodies  map[string]string // of the extra files, by ID
	failing map[string]bool   // IDs whose fetch fails
	fetched []string          // IDs, in fetch order
	onFetch func()
}

func (f *fakeRemote) list(ctx context.Context) ([]file, error) {
	fs, err := rcloneRemote{}.list(ctx)
	for i := range fs {
		fs[i].ID = cmp.Or(f.ids[fs[i].Path], "s"+hex.EncodeToString([]byte(fs[i].Path)))
	}
	return append(fs, f.extra...), err
}

func (f *fakeRemote) fetch(ctx context.Context, id, dest string) error {
	f.fetched = append(f.fetched, id)
	if f.onFetch != nil {
		f.onFetch()
	}
	if f.failing[id] {
		return errors.New("fetch failed")
	}
	body, ok := f.bodies[id]
	if !ok {
		p, err := hex.DecodeString(strings.TrimPrefix(id, "s"))
		if err != nil {
			return err
		}
		b, err := os.ReadFile(filepath.Join(f.src, string(p)))
		if err != nil {
			return err
		}
		body = string(b)
	}
	if err := os.WriteFile(dest, []byte(body), 0o600); err != nil {
		return err
	}
	// rclone gives a fetched file Google's ModTime.
	if i := slices.IndexFunc(f.extra, func(e file) bool { return e.ID == id }); i >= 0 {
		return os.Chtimes(dest, f.extra[i].ModTime, f.extra[i].ModTime)
	}
	return nil
}

// add puts an extra file named path with ID id and body, with its sha256,
// into f.
func (f *fakeRemote) add(path, id, body string, mod time.Time) {
	if f.bodies == nil {
		f.bodies = map[string]string{}
	}
	f.extra = slices.DeleteFunc(f.extra, func(e file) bool { return e.ID == id })
	e := file{Path: path, ID: id, Size: int64(len(body)), ModTime: mod}
	e.Hashes.SHA256 = hash([]byte(body))
	f.extra = append(f.extra, e)
	f.bodies[id] = body
}

func (f *fakeRemote) drop(id string) {
	f.extra = slices.DeleteFunc(f.extra, func(e file) bool { return e.ID == id })
}

// driveFixture is a stand-in Drive, a mirror directory and a manifest.
type driveFixture struct {
	t             *testing.T
	src, dir, mf  string
	remote        remote
	ctx           context.Context
	logs          string
	err           error
	before, after map[string][2]int64
}

func newDrive(t *testing.T) *driveFixture {
	src := standIn(t)
	return &driveFixture{t: t, src: src, dir: t.TempDir(), mf: filepath.Join(t.TempDir(), "drive.manifest"), remote: rcloneRemote{}, ctx: context.Background()}
}

func (d *driveFixture) run() error {
	d.t.Helper()
	d.before = state(d.t, d.dir)
	d.logs = captureStderr(d.t, func() { d.err = syncDrive(d.ctx, d.remote, d.dir, d.mf) })
	checkHistory(d.t, d.ctx, d.mf, d.err)
	d.after = state(d.t, d.dir)
	return d.err
}

func (d *driveFixture) mustRun() {
	d.t.Helper()
	if err := d.run(); err != nil {
		d.t.Fatalf("run: %v\n%s", err, d.logs)
	}
}

func (d *driveFixture) idle() {
	d.t.Helper()
	d.mustRun()
	if !maps.Equal(d.before, d.after) {
		d.t.Errorf("idle run changed the mirror:\nbefore %v\nafter  %v\n%s", d.before, d.after, d.logs)
	}
	if !strings.Contains(d.logs, "drive: 0 files changed on disk since the last run\n") || strings.Contains(d.logs, "deleted in Google") || !strings.Contains(d.logs, " 0 new, 0 updated, 0 renamed, 0 removed,") || !strings.Contains(d.logs, ", 0 failed\n") {
		d.t.Errorf("idle run logged changes:\n%s", d.logs)
	}
}

func (d *driveFixture) noKept() {
	d.t.Helper()
	if k := keptIn(d.t, d.dir, ""); len(k) > 0 {
		d.t.Errorf("unexpected kept copies %q\n%s", k, d.logs)
	}
}

// keptOnce checks that exactly one -kept- copy of stem holds body.
func (d *driveFixture) keptOnce(stem, body string) {
	d.t.Helper()
	d.copyOnce("-kept-", stem, body)
}

// deletedOnce checks that exactly one -deleted- copy of stem holds body.
func (d *driveFixture) deletedOnce(stem, body string) {
	d.t.Helper()
	d.copyOnce("-deleted-", stem, body)
}

func (d *driveFixture) copyOnce(tag, stem, body string) {
	d.t.Helper()
	var got []string
	for _, k := range copiesIn(d.t, d.dir, tag, stem) {
		got = append(got, read(d.t, k))
	}
	if len(got) != 1 || got[0] != body {
		d.t.Errorf("%s copies of %q: got %q, want one with %q", tag, stem, got, body)
	}
}

func (d *driveFixture) has(name, body string) {
	d.t.Helper()
	if got, err := os.ReadFile(filepath.Join(d.dir, name)); err != nil || string(got) != body {
		d.t.Errorf("%q: got %q (%v), want %q", name, got, err, body)
	}
}

func (d *driveFixture) gone(name string) {
	d.t.Helper()
	if _, err := os.Lstat(filepath.Join(d.dir, name)); !errors.Is(err, os.ErrNotExist) {
		d.t.Errorf("%q still on disk", name)
	}
}

func (d *driveFixture) logged(s string) {
	d.t.Helper()
	if !strings.Contains(d.logs, s) {
		d.t.Errorf("log lacks %q:\n%s", s, d.logs)
	}
}

// sameSizeEdit rewrites path with body, keeping its mtime.
func sameSizeEdit(t *testing.T, path, body string) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	write(t, path, body)
	if err := os.Chtimes(path, fi.ModTime(), fi.ModTime()); err != nil {
		t.Fatal(err)
	}
}

// Names of any spelling, "/" of Drive names included, mirror once and then
// stay put; local additions with names rclone would mangle are kept once.
func TestDriveNames(t *testing.T) {
	d := newDrive(t)
	names := []string{"plain.txt", " lead and trail ", "Q1／Q2 plan.txt", "F1／F2/in.txt", "ctl\x01", "nl\nx", "st*[x]{a}.txt", "#c;d", "sub dir/deep.txt"}
	for _, n := range names {
		os.MkdirAll(filepath.Dir(filepath.Join(d.src, n)), 0o700)
		write(t, filepath.Join(d.src, n), "body of "+n)
	}
	d.mustRun()
	d.logged("drive: 0 files changed on disk since the last run\n")
	d.logged(" 9 new, 0 updated, 0 renamed, 0 removed, 0 unchanged, 0 failed\n")
	if n := strings.Count(read(t, d.mf), "\n"); n != len(names) {
		t.Errorf("manifest has %d entries, want %d:\n%s", n, len(names), read(t, d.mf))
	}
	d.has("Q1／Q2 plan.txt", "body of Q1／Q2 plan.txt")
	d.has("F1／F2/in.txt", "body of F1／F2/in.txt")
	for range 3 {
		d.idle()
		d.logged(" 0 new, 0 updated, 0 renamed, 0 removed, 9 unchanged, 0 failed\n")
	}

	for _, n := range []string{"bad\xff", "c\x02l", "a b "} {
		write(t, filepath.Join(d.dir, n), "local "+n)
	}
	d.mustRun()
	d.logged("drive: 3 files changed on disk since the last run, kept as *-kept-")
	for _, n := range []string{"bad\xff", "c\x02l", "a b "} {
		d.gone(n)
		d.keptOnce(n, "local "+n)
	}
	d.idle()
	if strings.Contains(d.logs, "body") || strings.Contains(d.logs, "plain") || strings.Contains(d.logs, "local") {
		t.Errorf("log names files:\n%s", d.logs)
	}
}

func TestDriveKeepsLocalChanges(t *testing.T) {
	d := newDrive(t)
	for _, n := range []string{"a.txt", "b.txt", "c.txt", "gone.txt", "del.txt"} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	// a: same-size edit, mtime put back; x: added on disk; gone: edited on
	// disk and deleted in Google; del: deleted in Google; c: updated in Google.
	sameSizeEdit(t, filepath.Join(d.dir, "a.txt"), "GOOGLE a.txt")
	write(t, filepath.Join(d.dir, "x.txt"), "added")
	write(t, filepath.Join(d.dir, "gone.txt"), "edited gone")
	os.Remove(filepath.Join(d.src, "gone.txt"))
	os.Remove(filepath.Join(d.src, "del.txt"))
	write(t, filepath.Join(d.src, "c.txt"), "google c.txt v2")
	d.mustRun()
	d.has("a.txt", "google a.txt")
	d.keptOnce("a", "GOOGLE a.txt")
	d.keptOnce("x", "added")
	d.keptOnce("gone", "edited gone")
	d.has("c.txt", "google c.txt v2")
	d.gone("x.txt")
	d.gone("gone.txt")
	d.gone("del.txt")
	d.deletedOnce("del", "google del.txt")
	if len(keptIn(t, d.dir, "")) != 3 || len(copiesIn(t, d.dir, "-deleted-", "")) != 1 {
		t.Errorf("want 3 kept copies and 1 deleted, got %q", keptIn(t, d.dir, ""))
	}
	d.logged("drive: 3 files changed on disk since the last run, kept as *-kept-")
	d.logged("drive: 1 deleted in Google, kept as *-deleted-")
	d.logged("drive: done: 1 new, 1 updated, 0 renamed, 0 removed, 1 unchanged, 0 failed\n")
	if m := read(t, d.mf); strings.Contains(m, "-kept-") || strings.Contains(m, "-deleted-") || strings.Contains(m, "x.txt") || strings.Contains(m, "gone") {
		t.Errorf("manifest lists kept copies or gone files:\n%s", m)
	}
	d.idle()
}

// With no manifest, a file matching Google is just recorded; any other the
// sync or a fetch replaces or removes is kept. Older copies are left alone,
// and the next run changes nothing.
func TestDriveNoManifest(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	write(t, filepath.Join(d.src, "b.txt"), "google b")
	f.add("g.txt", "A", "ga", t0)
	f.add("g.txt", "B", "gb", t0)
	if err := os.Link(filepath.Join(d.src, "a.txt"), filepath.Join(d.dir, "a.txt")); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(d.dir, "b.txt"), "stale")
	write(t, filepath.Join(d.dir, "x.txt"), "local")
	write(t, filepath.Join(d.dir, "g~1.txt"), "unknown")
	write(t, filepath.Join(d.dir, "a-kept-2026-11-01-000000.txt"), "old kept")
	write(t, filepath.Join(d.dir, "a-deleted-2026-11-01.txt"), "old deleted")
	d.mustRun()
	if d.after["a.txt"] != d.before["a.txt"] {
		t.Error("a.txt, as Google has it, was replaced")
	}
	d.keptOnce("a", "old kept")
	d.deletedOnce("a", "old deleted")
	d.has("b.txt", "google b")
	d.keptOnce("b", "stale")
	d.gone("x.txt")
	d.keptOnce("x", "local")
	d.has("g~1.txt", "ga")
	d.has("g~2.txt", "gb")
	d.keptOnce("g~1", "unknown")
	if len(keptIn(t, d.dir, "")) != 4 || len(copiesIn(t, d.dir, "-deleted-", "")) != 1 {
		t.Errorf("copies: %q", slices.Collect(maps.Keys(d.after)))
	}
	d.logged("drive: 3 files changed on disk since the last run, kept as *-kept-")
	d.logged(" 3 new, 0 updated, 0 renamed, 0 removed, 1 unchanged, 0 failed\n")
	if m := read(t, d.mf); strings.Count(m, "\n") != 4 || strings.Contains(m, "x.txt") || strings.Contains(m, "-kept-") {
		t.Errorf("manifest:\n%s", m)
	}
	d.idle()
}

// With no manifest, a file at a numbered name whose fetch fails is not
// recorded, so the fetch that replaces it later keeps it.
func TestDriveNoManifestFetchFailure(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "ga", t0)
	f.extra[0].Hashes.SHA256 = "" // listed without one, as a Google document
	f.add("g.txt", "B", "gb", t0)
	write(t, filepath.Join(d.dir, "g~1.txt"), "unknown")
	f.failing = map[string]bool{"A": true}
	if err := d.run(); err == nil {
		t.Fatal("want the fetch error")
	}
	d.has("g~1.txt", "unknown")
	f.failing = nil
	d.mustRun()
	d.has("g~1.txt", "ga")
	d.keptOnce("g~1", "unknown")
}

// A file at the name a renamed Drive file moves to, with no entry or edited,
// keeps its copy when Google's new version of the renamed file is fetched
// over it the same night; so does one a peer puts there after the edited one
// is moved aside.
func TestRenameOccupantKept(t *testing.T) {
	for name, edit := range map[string]bool{"no entry": false, "edited": true} {
		d, f := newDupes(t)
		f.ids = map[string]string{"a.txt": "Y"}
		write(t, filepath.Join(d.src, "a.txt"), "google a")
		f.add("r.txt", "X1", "x1", t0)
		f.add("r.txt", "X2", "x2", t0)
		d.mustRun()
		// Y joins the group at r~3, or at r~1 that X1 frees.
		occupied, want := "r~3.txt", []string{"peer"}
		if edit {
			f.drop("X1")
			occupied, want = "r~1.txt", []string{"peer", "refill"}
			wrapRclone(t, "/a.txt ", "echo refill > "+filepath.Join(d.dir, occupied), "")
		}
		os.Remove(filepath.Join(d.src, "a.txt"))
		f.add("r.txt", "Y", "google a v2", t0.Add(time.Hour))
		if !edit {
			// Listed without one, as a Google document, so rename moves the occupant.
			f.extra[len(f.extra)-1].Hashes.SHA256 = ""
		}
		write(t, filepath.Join(d.dir, occupied), "peer")
		d.mustRun()
		d.has(occupied, "google a v2")
		var got []string
		for _, k := range keptIn(t, d.dir, "") {
			got = append(got, strings.TrimSpace(read(t, k)))
		}
		if slices.Sort(got); !slices.Equal(got, want) {
			t.Errorf("%s: kept %q, want %q", name, got, want)
		}
		if k := keptIn(t, d.dir, ""); !edit && len(k) == 1 {
			hasHistory(t, historyOf(t, d.mf), "drive", "kept", "-", hash([]byte("peer")), strconv.Quote(occupied), strconv.Quote(filepath.Base(k[0])))
		}
		d.idle()
	}
}

// A file with no entry that a peer replaces during the sync, keeping
// Google's ModTime, is not recorded, so the next run keeps it.
func TestDriveNoManifestPeerEditDuringSync(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	a := filepath.Join(d.dir, "a.txt")
	wrapRclone(t, " sync ", "", "echo peer > "+a+"; touch -r "+filepath.Join(d.src, "a.txt")+" "+a)
	d.mustRun()
	if strings.Contains(read(t, d.mf), "a.txt") {
		t.Errorf("peer's file recorded:\n%s", read(t, d.mf))
	}
	rcloneBin = cmp.Or(os.Getenv("RCLONE"), testRclone)
	d.mustRun()
	d.has("a.txt", "google a")
	d.keptOnce("a", "peer\n")
}

// A manifest lost after normal runs loses nothing: what Google deleted,
// renamed or changed and what changed on disk are all kept.
func TestDriveManifestLost(t *testing.T) {
	d := newDrive(t)
	for _, n := range []string{"a.txt", "b.txt", "c.txt", "e.txt", "o.txt", "s.txt"} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	d.idle()
	write(t, filepath.Join(d.dir, "a.txt"), "edited a")
	sameSizeEdit(t, filepath.Join(d.dir, "s.txt"), "GOOGLE s.txt")
	write(t, filepath.Join(d.src, "b.txt"), "google b v2")
	os.Remove(filepath.Join(d.src, "c.txt"))
	os.Rename(filepath.Join(d.src, "e.txt"), filepath.Join(d.src, "f.txt"))
	write(t, filepath.Join(d.dir, "x.txt"), "local")
	os.Remove(d.mf)
	d.mustRun()
	d.has("a.txt", "google a.txt")
	d.has("b.txt", "google b v2")
	d.has("f.txt", "google e.txt")
	d.has("o.txt", "google o.txt")
	d.has("s.txt", "google s.txt")
	for stem, body := range map[string]string{"a": "edited a", "b": "google b.txt", "c": "google c.txt", "e": "google e.txt", "s": "GOOGLE s.txt", "x": "local"} {
		d.keptOnce(stem, body)
	}
	if k := keptIn(t, d.dir, ""); len(k) != 6 {
		t.Errorf("kept copies %q, want 6", k)
	}
	d.idle()
}

func TestDriveBadManifest(t *testing.T) {
	h := strings.Repeat("a", 64)
	good := h + "  2026-11-22T00:00:00Z  -  a.txt\n"
	for name, m := range map[string]string{
		"truncated":      good[:50],
		"no newline":     good[:len(good)-1],
		"junk":           "hello\n",
		"bad time":       h + "  yesterday  -  a.txt\n",
		"duplicate name": good + good,
		"bad ID":         h + `  2026-11-22T00:00:00Z  "\q"  a.txt` + "\n",
		"empty ID":       h + `  2026-11-22T00:00:00Z  ""  a.txt` + "\n",
		"one space":      h + " 2026-11-22T00:00:00Z  -  a.txt\n",
	} {
		d := newDrive(t)
		write(t, filepath.Join(d.src, "a.txt"), "google")
		write(t, d.mf, m)
		write(t, filepath.Join(d.dir, "a.txt"), "local")
		if err := d.run(); err == nil || !strings.Contains(err.Error(), "manifest") {
			t.Errorf("%s: want a manifest error, got %v", name, err)
		}
		if read(t, filepath.Join(d.dir, "a.txt")) != "local" || read(t, d.mf) != m || len(keptIn(t, d.dir, "")) != 0 {
			t.Errorf("%s: failed run touched files", name)
		}
	}
}

// A failing download leaves the local copy in place, now and on later nights,
// and the deletions rclone skips for it are kept once it succeeds.
func TestDriveDownloadFailure(t *testing.T) {
	d := newDrive(t)
	for _, n := range []string{"u.txt", "g.txt", "ok.txt"} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	write(t, filepath.Join(d.src, "u.txt"), "google u.txt, longer")
	os.Chmod(filepath.Join(d.src, "u.txt"), 0)
	t.Cleanup(func() { os.Chmod(filepath.Join(d.src, "u.txt"), 0o600) })
	os.Remove(filepath.Join(d.src, "g.txt"))
	for range 2 {
		if err := d.run(); err == nil {
			t.Fatal("want a download error")
		}
		d.has("u.txt", "google u.txt")
		d.has("g.txt", "google g.txt")
		d.noKept()
		d.logged(", 1 failed\n")
	}
	os.Chmod(filepath.Join(d.src, "u.txt"), 0o600)
	d.mustRun()
	d.has("u.txt", "google u.txt, longer")
	d.gone("g.txt")
	d.deletedOnce("g", "google g.txt")
	d.noKept()
	d.logged(" 0 new, 1 updated, 0 renamed, 0 removed, 1 unchanged, 0 failed\n")
}

// wrapRclone makes the rclone commands whose arguments contain match run the
// shell commands pre before and post after the real one.
func wrapRclone(t *testing.T, match, pre, post string) {
	t.Helper()
	script := filepath.Join(t.TempDir(), "rclone")
	write(t, script, "#!/bin/sh\ncase \" $* \" in *\""+match+"\"*) ;; *) exec "+rcloneBin+" \"$@\";; esac\n"+
		pre+"\n"+rcloneBin+" \"$@\"\nrc=$?\n"+post+"\nexit $rc\n")
	if err := os.Chmod(script, 0o700); err != nil {
		t.Fatal(err)
	}
	rcloneBin = script
}

// Peer changes during the run: before rclone replaces or deletes a file they
// are kept at once; after it, the manifest leaves the file out, so the next
// run keeps it.
func TestDriveChangesDuringRun(t *testing.T) {
	d := newDrive(t)
	for _, n := range []string{"a.txt", "b.txt"} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	write(t, filepath.Join(d.src, "a.txt"), "google a.txt v2")
	real := rcloneBin
	wrapRclone(t, " sync ", "echo peer >> "+filepath.Join(d.dir, "a.txt")+"; echo new > "+filepath.Join(d.dir, "new.txt"),
		"echo late >> "+filepath.Join(d.dir, "b.txt"))
	d.mustRun()
	rcloneBin = real
	d.has("a.txt", "google a.txt v2")
	d.keptOnce("a", "google a.txtpeer\n")
	d.keptOnce("new", "new\n")
	if strings.Contains(read(t, d.mf), "b.txt") {
		t.Errorf("manifest blessed b.txt, changed during the run:\n%s", read(t, d.mf))
	}
	d.mustRun()
	d.keptOnce("b", "google b.txtlate\n")
	d.has("b.txt", "google b.txt")
	d.idle()
}

// A SIGTERM reaches rclone as SIGTERM; the run then sorts out what it did,
// writes the manifest and fails.
func TestDriveStopped(t *testing.T) {
	d := newDrive(t)
	for _, n := range []string{"a.txt", "b.txt"} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	write(t, filepath.Join(d.dir, "a.txt"), "edited")
	write(t, filepath.Join(d.src, "b.txt"), "google b.txt v2")
	d.stopAtSync()
	d.keptOnce("a", "edited")
	d.has("b.txt", "google b.txt")
	if m := read(t, d.mf); !strings.Contains(m, "  b.txt\n") || strings.Contains(m, "a.txt") {
		t.Errorf("manifest after the stop:\n%s", m)
	}
}

// stopAtSync runs with a SIGTERM once rclone sync starts.
func (d *driveFixture) stopAtSync() {
	t := d.t
	t.Helper()
	real := rcloneBin
	defer func() { rcloneBin = real }()
	mark := filepath.Join(t.TempDir(), "mark")
	wrapRclone(t, " sync ", "trap 'echo TERM > "+mark+"; exit 143' TERM; touch "+mark+".started; sleep 30 >/dev/null 2>&1 & wait", "")
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		for {
			if _, err := os.Stat(mark + ".started"); err == nil {
				cancel()
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}()
	var err error
	start := time.Now()
	d.logs = captureStderr(t, func() { err = syncDrive(ctx, d.remote, d.dir, d.mf) })
	if err == nil {
		t.Error("stopped run succeeded")
	}
	if time.Since(start) > 20*time.Second || read(t, mark) != "TERM\n" {
		t.Error("rclone was not sent SIGTERM")
	}
}

// An empty or failed listing neither deletes nor renames anything; kept
// copies alone are no reason to refuse.
func TestDriveEmptyListingKeepsLocal(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.dir, "z-deleted-2026-01-01.txt"), "copy")
	d.mustRun()
	d.has("z-deleted-2026-01-01.txt", "copy")
	f.ids = map[string]string{"a.txt": "A", "b.txt": "A"}
	write(t, filepath.Join(d.src, "a.txt"), "google")
	d.mustRun()
	os.Rename(filepath.Join(d.src, "a.txt"), filepath.Join(d.src, "b.txt"))
	d.remote = failingList{}
	if err := d.run(); err == nil || !strings.Contains(err.Error(), "listing Drive") {
		t.Errorf("want a listing error, got %v", err)
	}
	if !maps.Equal(d.before, d.after) {
		t.Errorf("failed listing changed the mirror: %v", d.after)
	}
	d.remote = f
	os.Remove(filepath.Join(d.src, "b.txt"))
	if err := d.run(); err == nil || !strings.Contains(err.Error(), "nothing is shared") {
		t.Errorf("want a refusal, got %v", err)
	}
	if !maps.Equal(d.before, d.after) {
		t.Errorf("empty listing changed the mirror: %v", d.after)
	}
	d.has("a.txt", "google")
}

type failingList struct{ rcloneRemote }

func (failingList) list(context.Context) ([]file, error) { return nil, errors.New("503") }

// Temporary files of Syncthing and rclone are neither backed up nor touched.
func TestDriveTemps(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	write(t, filepath.Join(d.src, "z.partial"), "google")
	write(t, filepath.Join(d.src, ".syncthing.q.tmp"), "google")
	write(t, filepath.Join(d.src, "k-kept-2026-01-01-000000.txt"), "google")
	write(t, filepath.Join(d.src, "d-deleted-2026-01-01.txt"), "google")
	d.mustRun()
	d.gone("z.partial")
	d.gone(".syncthing.q.tmp")
	d.gone("k-kept-2026-01-01-000000.txt")
	d.gone("d-deleted-2026-01-01.txt")
	for _, n := range []string{".syncthing.x.tmp", "y.partial"} {
		write(t, filepath.Join(d.dir, n), "temp")
	}
	d.idle()
	for _, n := range []string{".syncthing.x.tmp", "y.partial"} {
		d.has(n, "temp")
	}
	if m := read(t, d.mf); strings.Contains(m, "partial") || strings.Contains(m, "syncthing") {
		t.Errorf("manifest lists temporary files:\n%s", m)
	}
}

func newDupes(t *testing.T) (*driveFixture, *fakeRemote) {
	d := newDrive(t)
	f := &fakeRemote{src: d.src}
	d.remote = f
	return d, f
}

var t0 = time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)

// Files sharing a name are all numbered, keep their numbers and are fetched
// again only when Google changed them.
func TestDuplicatesNumbered(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "r.txt"), "standin r")
	write(t, filepath.Join(d.src, "s.txt"), "standin s")
	d.mustRun()
	d.has("r.txt", "standin r")

	// A second r.txt: both are numbered, the old one renamed, the new one fetched.
	f.add("r.txt", "X1", "extra r", t0)
	d.mustRun()
	d.gone("r.txt")
	d.has("r~1.txt", "extra r")
	d.has("r~2.txt", "standin r")
	if !slices.Equal(f.fetched, []string{"X1"}) || d.after["r~2.txt"][0] != d.before["r.txt"][0] {
		t.Errorf("fetched %q, want only X1 and the old r.txt renamed", f.fetched)
	}
	d.noKept()
	d.logged("drive: 1 duplicate-name groups, 2 files numbered\n")
	d.logged(" 1 new, 0 updated, 1 renamed, 0 removed, 2 unchanged, 0 failed\n")

	f.fetched = nil
	d.idle()
	if len(f.fetched) != 0 {
		t.Errorf("unchanged duplicates fetched again: %q", f.fetched)
	}

	f.add("r.txt", "X1", "extra r v2", t0.Add(time.Hour))
	d.mustRun()
	d.has("r~1.txt", "extra r v2")
	d.has("r~2.txt", "standin r")
	if !slices.Equal(f.fetched, []string{"X1"}) {
		t.Errorf("fetched %q, want X1 again", f.fetched)
	}
	d.noKept()
	d.logged(" 0 new, 1 updated, 0 renamed, 0 removed, 2 unchanged, 0 failed\n")
	if strings.Contains(d.logs, "X1") || strings.Contains(d.logs, "r~") {
		t.Errorf("log names IDs or files:\n%s", d.logs)
	}
}

// A new member takes the lowest free number that is not a real name; a
// member Google deleted is retired like any deletion.
func TestDuplicatesLowestFree(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "g~1.txt"), "real g~1")
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	d.has("g~1.txt", "real g~1")
	d.has("g~2.txt", "a")
	d.has("g~3.txt", "b")
	f.drop("A")
	f.add("g.txt", "C", "c", t0)
	// h~1.txt is the name of a group itself.
	f.add("h.txt", "H1", "h1", t0)
	f.add("h.txt", "H2", "h2", t0)
	f.add("h~1.txt", "K1", "k1", t0)
	f.add("h~1.txt", "K2", "k2", t0)
	d.mustRun()
	d.has("g~1.txt", "real g~1")
	d.has("g~2.txt", "c")
	d.has("g~3.txt", "b")
	d.has("h~2.txt", "h1")
	d.has("h~3.txt", "h2")
	d.has("h~1~1.txt", "k1")
	d.has("h~1~2.txt", "k2")
	d.gone("h~1.txt")
	d.deletedOnce("g~2", "a")
	d.noKept()
	d.idle()
}

// A file Google deleted whose name became a group's is kept as deleted.
func TestDuplicatesReplacePlain(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "g.txt"), "old g")
	write(t, filepath.Join(d.src, "o.txt"), "o")
	d.mustRun()
	os.Remove(filepath.Join(d.src, "g.txt"))
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	d.gone("g.txt")
	d.has("g~1.txt", "a")
	d.has("g~2.txt", "b")
	d.deletedOnce("g", "old g")
	d.noKept()
	d.logged(" 2 new, 0 updated, 0 renamed, 0 removed,")
	d.idle()
}

// globEscape gives the rclone filter matching exactly one name.
func TestGlobEscape(t *testing.T) {
	standIn(t)
	dir := t.TempDir()
	names := []string{" lead", "nbsp\u00a0", "\u3000ideo", `a*b`, `a?b`, `a[b]`, `a{b,c}`, `a\b`, `a b `, "#a;b", "a**b", "a.b"}
	for _, n := range names {
		write(t, filepath.Join(dir, n), n)
	}
	for _, n := range names {
		d := &driveRun{dir: dir}
		got, err := d.local(context.Background(), "--include", globEscape(n))
		if err != nil || len(got) != 1 || got[n].Path != n {
			t.Errorf("--include %s matched %v (%v)", globEscape(n), slices.Collect(maps.Keys(got)), err)
		}
	}
}

// When only one file keeps a name it gets the plain name, without a fetch.
func TestDuplicatesShrink(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	write(t, filepath.Join(d.src, "g.txt"), "b")
	d.mustRun()
	d.has("g~1.txt", "a")
	d.has("g~2.txt", "b")
	f.drop("A")
	f.fetched = nil
	d.mustRun()
	d.gone("g~1.txt")
	d.gone("g~2.txt")
	d.has("g.txt", "b")
	if d.after["g.txt"][0] != d.before["g~2.txt"][0] {
		t.Error("the last file of the group was fetched again, not renamed")
	}
	if len(f.fetched) != 0 {
		t.Errorf("shrink fetched %q", f.fetched)
	}
	d.noKept()
	d.idle()
}

// Kept-copy rules apply to numbered files: local edits and additions under
// numbered or plain group names are kept before Google's version returns.
func TestDuplicatesLocalChanges(t *testing.T) {
	d, f := newDupes(t)
	f.add("st*[x] {a}.txt", "A", "a", t0)
	f.add("st*[x] {a}.txt", "B", "b", t0)
	f.add("d／e.txt", "D1", "d1", t0)
	f.add("d／e.txt", "D2", "d2", t0)
	write(t, filepath.Join(d.src, "o.txt"), "o")
	d.mustRun()
	d.has("d／e~1.txt", "d1")
	d.has("d／e~2.txt", "d2")
	d.has("st*[x] {a}~1.txt", "a")
	d.has("st*[x] {a}~2.txt", "b")
	d.idle()
	sameSizeEdit(t, filepath.Join(d.dir, "st*[x] {a}~1.txt"), "A")
	write(t, filepath.Join(d.dir, "st*[x] {a}.txt"), "plain added")
	f.fetched = nil
	d.mustRun()
	d.has("st*[x] {a}~1.txt", "a")
	d.keptOnce("st*[x] {a}~1", "A")
	d.keptOnce("st*[x] {a}", "plain added")
	d.gone("st*[x] {a}.txt")
	if !slices.Equal(f.fetched, []string{"A"}) {
		t.Errorf("fetched %q, want A", f.fetched)
	}
	d.idle()
}

// An edit landing during the fetch is kept when the fetched file replaces it.
func TestDuplicatesEditDuringFetch(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	f.add("g.txt", "A", "a v2", t0.Add(time.Hour))
	f.onFetch = func() { write(t, filepath.Join(d.dir, "g~1.txt"), "peer") }
	d.mustRun()
	d.has("g~1.txt", "a v2")
	d.keptOnce("g~1", "peer")
}

// A failing fetch leaves the local copy, without kept copies on later nights.
func TestDuplicatesFetchFailure(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	f.add("g.txt", "B", "b v2", t0.Add(time.Hour))
	f.failing = map[string]bool{"B": true}
	for range 2 {
		if err := d.run(); err == nil {
			t.Fatal("want a fetch error")
		}
		d.has("g~2.txt", "b")
		d.noKept()
		d.logged(", 1 failed\n")
	}
	f.failing = nil
	d.mustRun()
	d.has("g~2.txt", "b v2")
	d.noKept()
}

// With the manifest lost, numbering is redone and nothing is lost.
func TestDuplicatesStateLost(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	os.Remove(d.mf)
	d.mustRun()
	d.has("g~1.txt", "a")
	d.has("g~2.txt", "b")
	d.noKept()
	d.idle()
}

func TestNumbered(t *testing.T) {
	for _, c := range [][3]string{
		{"r.docx", "r~2.docx"}, {"dir/r", "dir/r~2"}, {".bashrc", ".bashrc~2"},
		{"a.b/c", "a.b/c~2"}, {"x.tar.gz", "x.tar~2.gz"},
	} {
		if got := numbered(c[0], 2); got != c[1] || !isNumbered(got, c[0]) {
			t.Errorf("numbered(%q, 2) = %q, want %q", c[0], got, c[1])
		}
	}
	for _, n := range []string{"r~0.docx", "r~02.docx", "r~.docx", "r~1x.docx", "q~1.docx"} {
		if isNumbered(n, "r.docx") {
			t.Errorf("%q taken for a numbered r.docx", n)
		}
	}
}

// A manifest that cannot be written leaves the previous one in place.
func TestDriveManifestWriteFailure(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	d.mustRun()
	before := read(t, d.mf)
	write(t, filepath.Join(d.src, "b.txt"), "google")
	if err := os.Mkdir(filepath.Join(filepath.Dir(d.mf), ".syncthing.drive.manifest.tmp"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := d.run(); err == nil {
		t.Error("unwritable manifest did not fail the run")
	}
	if read(t, d.mf) != before {
		t.Error("manifest changed")
	}
}

// A stopped run fails and does not start the Drive part.
func TestRunStopped(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	t.Setenv("GOOGLE_CONTACTS_TOKEN", "")
	err := runCmd(ctx, []string{"-state", t.TempDir(), "-contacts", t.TempDir(), "-drive", filepath.Join(t.TempDir(), "none")})
	if !errors.Is(err, context.Canceled) || strings.Contains(err.Error(), "drive") {
		t.Errorf("want a stop error without the Drive part, got %v", err)
	}
}

// Files left by a killed run's fetches are removed.
func TestDriveStagedLeftover(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	write(t, filepath.Join(d.dir, stagedPrefix+"3.tmp"), "half")
	d.mustRun()
	d.gone(stagedPrefix + "3.tmp")
}

// A shortcut's ID holds a tab; the manifest carries it.
func TestShortcutID(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "target\tshortcut", "a", t0)
	f.add("g.txt", "B", "b", t0)
	d.mustRun()
	f.fetched = nil
	d.idle()
	d.idle()
	if len(f.fetched) != 0 {
		t.Errorf("fetched again: %q", f.fetched)
	}
}

// One Drive file shared along several paths is backed up at each.
func TestSameIDTwoPaths(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "x.txt"), "x")
	f.ids = map[string]string{"x.txt": "X"}
	f.add("r.txt", "A", "a", t0)
	f.add("q.txt", "B", "b", t0)
	f.extra = append(f.extra, file{Path: "r.txt", ID: "X", Size: 1, ModTime: t0}, file{Path: "q.txt", ID: "X", Size: 1, ModTime: t0})
	f.bodies["X"] = "x"
	d.mustRun()
	f.fetched = nil
	for range 3 {
		d.idle()
	}
	d.has("x.txt", "x")
	d.has("r~1.txt", "a")
	d.has("r~2.txt", "x")
	d.has("q~1.txt", "b")
	d.has("q~2.txt", "x")
	if len(f.fetched) != 0 {
		t.Errorf("fetched again: %q", f.fetched)
	}
}

// A file Google changes during the run is recorded as rclone wrote it.
func TestDriveGoogleEditDuringRun(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	write(t, filepath.Join(d.src, "o.txt"), "o")
	d.mustRun()
	a := filepath.Join(d.src, "a.txt")
	real := rcloneBin
	wrapRclone(t, " sync ", "echo edited > "+a+"; touch -d '2030-01-01 00:00' "+a, "")
	d.mustRun()
	rcloneBin = real
	d.has("a.txt", "edited\n")
	d.idle()
	d.noKept()
}

// A stop between fetches ends them.
func TestFetchStopsWhenStopped(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d.ctx = ctx
	f.onFetch = cancel
	if err := d.run(); err == nil {
		t.Error("stopped run succeeded")
	}
	if len(f.fetched) != 1 {
		t.Errorf("fetched %q after the stop", f.fetched)
	}
}

// A kept own version is not moved back over a file a peer put in its place.
func TestRestoreKeepsPeerFile(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "u.txt"), "google u")
	d.mustRun()
	u := filepath.Join(d.src, "u.txt")
	write(t, u, "google u, longer")
	os.Chmod(u, 0)
	t.Cleanup(func() { os.Chmod(u, 0o600) })
	wrapRclone(t, " moveto ", "echo peer > "+filepath.Join(d.dir, "u.txt"), "")
	if err := d.run(); err == nil {
		t.Fatal("want a download error")
	}
	d.has("u.txt", "peer\n")
	d.keptOnce("u", "google u")
}

// Files Google deleted are kept as -deleted-<date>, or -deleted-<time> when
// that name is taken; the copies are left alone from then on, and a file
// restored in Google comes back beside its copy.
func TestDriveDeleted(t *testing.T) {
	d := newDrive(t)
	names := []string{"a.txt", "b.txt", "e.txt", "o.txt", "sub/c", " lead", "st*[x]{a}.txt", "Q1／Q2.txt"}
	os.Mkdir(filepath.Join(d.src, "sub"), 0o700)
	for _, n := range names {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	write(t, filepath.Join(d.dir, "b-deleted-2026-11-23.txt"), "taken")
	write(t, filepath.Join(d.dir, "e-deleted-2026-11-23.txt"), "taken")
	write(t, filepath.Join(d.dir, "e-deleted-2026-11-23-001502.txt"), "taken")
	for _, n := range names {
		if n != "o.txt" {
			os.Remove(filepath.Join(d.src, n))
		}
	}
	os.Remove(filepath.Join(d.src, "sub"))
	d.mustRun()
	for _, n := range names {
		if n != "o.txt" {
			d.gone(n)
		}
	}
	d.has("a-deleted-2026-11-23.txt", "google a.txt")
	d.has("b-deleted-2026-11-23.txt", "taken")
	d.has("b-deleted-2026-11-23-001502.txt", "google b.txt")
	d.has("sub/c-deleted-2026-11-23", "google sub/c")
	d.has(" lead-deleted-2026-11-23", "google  lead")
	d.has("st*[x]{a}-deleted-2026-11-23.txt", "google st*[x]{a}.txt")
	d.has("Q1／Q2-deleted-2026-11-23.txt", "google Q1／Q2.txt")
	d.keptOnce("e", "google e.txt")
	d.logged("drive: 1 files changed on disk since the last run, kept as *-kept-")
	d.logged("drive: 6 deleted in Google, kept as *-deleted-2026-11-23*\n")
	d.logged(" 0 new, 0 updated, 0 renamed, 0 removed, 1 unchanged, 0 failed\n")
	if m := read(t, d.mf); strings.Contains(m, "deleted") || strings.Count(m, "\n") != 1 {
		t.Errorf("manifest after deletions:\n%s", m)
	}
	d.idle()
	write(t, filepath.Join(d.src, "a.txt"), "google a.txt")
	d.mustRun()
	d.has("a.txt", "google a.txt")
	d.has("a-deleted-2026-11-23.txt", "google a.txt")
	d.idle()
	if strings.Contains(d.logs, "a.txt") || strings.Contains(d.logs, "lead") {
		t.Errorf("log names files:\n%s", d.logs)
	}
}

// Google's renames and moves are followed by ID without a download, also
// along a chain of renames; an edited file is kept and its new name fetched;
// a file at the new name is kept first.
func TestDriveRenameByID(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "A", "b.txt": "B", "c.txt": "C", "e.txt": "E", "o.txt": "O", "1.txt": "P1", "2.txt": "P2"}
	for n := range f.ids {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	if m := read(t, d.mf); strings.Contains(m, "  -  ") {
		t.Errorf("manifest lacks IDs:\n%s", m)
	}
	mv := func(from, to string) {
		os.MkdirAll(filepath.Dir(filepath.Join(d.src, to)), 0o700)
		if err := os.Rename(filepath.Join(d.src, from), filepath.Join(d.src, to)); err != nil {
			t.Fatal(err)
		}
		f.ids[to] = f.ids[from]
	}
	mv("a.txt", "z.txt")
	mv("c.txt", "d.txt")
	sameSizeEdit(t, filepath.Join(d.dir, "c.txt"), "GOOGLE c.txt")
	mv("e.txt", "x.txt")
	write(t, filepath.Join(d.dir, "x.txt"), "local x")
	mv("o.txt", "sub/o.txt")
	mv("2.txt", "3.txt")
	mv("1.txt", "2.txt")
	mv("b.txt", "b2.txt")
	write(t, filepath.Join(d.src, "b2.txt"), "google b.txt v2")
	d.mustRun()
	for from, to := range map[string]string{"a.txt": "z.txt", "e.txt": "x.txt", "1.txt": "2.txt", "2.txt": "3.txt"} {
		d.has(to, "google "+from)
		if d.after[to][0] != d.before[from][0] {
			t.Errorf("%s was downloaded again, not renamed from %s", to, from)
		}
	}
	d.gone("a.txt")
	d.gone("e.txt")
	d.gone("1.txt")
	d.has("sub/o.txt", "google o.txt")
	d.gone("o.txt")
	d.has("b2.txt", "google b.txt v2")
	d.gone("b.txt")
	d.gone("c.txt")
	d.keptOnce("c", "GOOGLE c.txt")
	d.has("d.txt", "google c.txt")
	d.keptOnce("x", "local x")
	if k := copiesIn(t, d.dir, "-deleted-", ""); len(k) != 0 {
		t.Errorf("renames kept as deleted: %q", k)
	}
	d.logged(" 1 new, 1 updated, 6 renamed, 0 removed, 5 unchanged, 0 failed\n")
	d.idle()
}

// A stop after a rename leaves the renamed file in the manifest under its new
// name and the files rclone did not reach under their old entries.
func TestDriveStoppedAfterRename(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "A", "b.txt": "A", "c.txt": "C"}
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	write(t, filepath.Join(d.src, "c.txt"), "google c")
	d.mustRun()
	os.Rename(filepath.Join(d.src, "a.txt"), filepath.Join(d.src, "b.txt"))
	os.Remove(filepath.Join(d.src, "c.txt"))
	d.stopAtSync()
	d.has("b.txt", "google a")
	d.has("c.txt", "google c")
	if m := read(t, d.mf); !strings.Contains(m, "  b.txt\n") || !strings.Contains(m, "  c.txt\n") || strings.Contains(m, "a.txt") {
		t.Errorf("manifest after the stop:\n%s", m)
	}
	d.mustRun()
	d.deletedOnce("c", "google c")
	d.has("b.txt", "google a")
	d.idle()
}

// A file shared along several paths follows a move of one path; a path it
// loses is removed, as it is still backed up at the other.
func TestSameIDPathMoved(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"x.txt": "X", "y.txt": "X", "z.txt": "X"}
	write(t, filepath.Join(d.src, "x.txt"), "x")
	write(t, filepath.Join(d.src, "y.txt"), "x")
	d.mustRun()
	d.has("y.txt", "x")
	os.Rename(filepath.Join(d.src, "y.txt"), filepath.Join(d.src, "z.txt"))
	d.mustRun()
	d.gone("y.txt")
	d.has("z.txt", "x")
	if d.after["z.txt"][0] != d.before["y.txt"][0] {
		t.Error("z.txt was downloaded again, not renamed")
	}
	d.logged(" 0 new, 0 updated, 1 renamed, 0 removed,")
	os.Remove(filepath.Join(d.src, "z.txt"))
	d.mustRun()
	d.gone("z.txt")
	d.has("x.txt", "x")
	d.logged(" 0 new, 0 updated, 0 renamed, 1 removed,")
	if k := copiesIn(t, d.dir, "-deleted-", ""); len(k) != 0 {
		t.Errorf("lost path kept as deleted: %q", k)
	}
	d.noKept()
	d.idle()
}

// A manifest with IDs only for numbered files: a rename is seen as a
// deletion once, after which every entry has its ID and renames follow.
func TestDriveOldManifest(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "A", "b.txt": "A", "c.txt": "A", "o.txt": "O"}
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	write(t, filepath.Join(d.src, "o.txt"), "google o")
	d.mustRun()
	write(t, d.mf, strings.NewReplacer(`"A"`, "-", `"O"`, "-").Replace(read(t, d.mf)))
	os.Rename(filepath.Join(d.src, "a.txt"), filepath.Join(d.src, "b.txt"))
	d.mustRun()
	d.deletedOnce("a", "google a")
	d.has("b.txt", "google a")
	d.logged(" 1 new, 0 updated, 0 renamed, 0 removed, 1 unchanged,")
	if m := read(t, d.mf); strings.Contains(m, "  -  ") {
		t.Errorf("new manifest lacks IDs:\n%s", m)
	}
	os.Rename(filepath.Join(d.src, "b.txt"), filepath.Join(d.src, "c.txt"))
	d.mustRun()
	d.has("c.txt", "google a")
	d.logged(" 0 new, 0 updated, 1 renamed, 0 removed,")
	d.deletedOnce("a", "google a")
	if k := copiesIn(t, d.dir, "-deleted-", ""); len(k) != 1 {
		t.Errorf("deleted copies %q, want only a's", k)
	}
	d.idle()
}

// A rename that fails, here to a name too long for the disk, leaves that
// file to the sync and the rest of the mirror goes on.
func TestRenameFailureIsolated(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "A", "o.txt": "O"}
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	write(t, filepath.Join(d.src, "o.txt"), "o")
	d.mustRun()
	os.Remove(filepath.Join(d.src, "a.txt"))
	f.add(strings.Repeat("ą", 130)+".txt", "A", "google a", t0)
	write(t, filepath.Join(d.src, "o.txt"), "o v2")
	if err := d.run(); err == nil {
		t.Error("failed rename did not fail the run")
	}
	d.has("o.txt", "o v2")
	d.has("a.txt", "google a")
	d.noKept()
	d.logged(", 1 failed\n")
}

// A file renamed into a group whose fetch fails or is stopped keeps its bytes
// under the old name until the new one is in place.
func TestRenameIntoGroupNotFetched(t *testing.T) {
	for _, stop := range []bool{false, true} {
		d, f := newDupes(t)
		f.ids = map[string]string{"a.txt": "Y"}
		write(t, filepath.Join(d.src, "a.txt"), "google a")
		f.add("r.txt", "X1", "x1", t0)
		f.add("r.txt", "X2", "x2", t0)
		d.mustRun()
		// Y takes r~1, which still holds X1, Google's deleted file.
		f.drop("X1")
		os.Remove(filepath.Join(d.src, "a.txt"))
		f.add("r.txt", "Y", "google a", t0)
		f.failing = map[string]bool{"Y": true}
		ctx, cancel := context.WithCancel(context.Background())
		if stop {
			d.ctx, f.onFetch = ctx, cancel
		}
		if err := d.run(); err == nil {
			t.Error("want a fetch error")
		}
		cancel()
		d.has("a.txt", "google a")
		d.ctx, f.failing, f.onFetch = context.Background(), nil, nil
		d.mustRun()
		d.gone("a.txt")
		d.has("r~1.txt", "google a")
		d.deletedOnce("r~1", "x1")
		d.noKept()
		d.idle()
	}
}

// A rename rclone completes before failing is recorded as done.
func TestRenameFailsAfterMove(t *testing.T) {
	d, f := newDupes(t)
	f.add("g.txt", "A", "a", t0)
	f.add("g.txt", "B", "b", t0)
	f.ids = map[string]string{"h.txt": "H"}
	write(t, filepath.Join(d.src, "h.txt"), "google h")
	d.mustRun()
	os.Remove(filepath.Join(d.src, "h.txt"))
	f.add("g.txt", "H", "google h", t0)
	real := rcloneBin
	wrapRclone(t, " moveto ", "", "exit 143")
	d.run()
	rcloneBin = real
	d.has("g~3.txt", "google h")
	if !strings.Contains(read(t, d.mf), "  g~3.txt\n") {
		t.Errorf("manifest lacks the renamed file:\n%s", read(t, d.mf))
	}
	d.idle()
	d.noKept()
}

// A new file Google puts at the old name of one renamed into a group does
// not cost the renamed one its bytes while its fetch fails.
func TestRenameIntoGroupOldNameReused(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "Y"}
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	f.add("r.txt", "X1", "x1", t0)
	f.add("r.txt", "X2", "x2", t0)
	d.mustRun()
	f.drop("X1")
	f.ids = map[string]string{"a.txt": "Z"}
	write(t, filepath.Join(d.src, "a.txt"), "new a, longer")
	f.add("r.txt", "Y", "google a", t0)
	f.failing = map[string]bool{"Y": true}
	if err := d.run(); err == nil {
		t.Error("want a fetch error")
	}
	d.has("a.txt", "new a, longer")
	d.keptOnce("a", "google a")
}

// An old manifest's file Google deleted, whose name two new files now share,
// is kept as deleted.
func TestOldManifestPlainBecameGroup(t *testing.T) {
	d, f := newDupes(t)
	write(t, filepath.Join(d.src, "g.txt"), "old g")
	write(t, filepath.Join(d.src, "o.txt"), "o")
	d.mustRun()
	write(t, d.mf, regexp.MustCompile(`"[^"]*"`).ReplaceAllString(read(t, d.mf), "-"))
	os.Remove(filepath.Join(d.src, "g.txt"))
	f.add("g.txt", "N1", "n1", t0)
	f.add("g.txt", "N2", "n2", t0)
	d.mustRun()
	d.deletedOnce("g", "old g")
	d.noKept()
}

// A path or name Google drops on the night it also edits the file is not
// kept: its newer version is backed up at the other name.
func TestRenameAndEditSameNight(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"x.txt": "X", "y.txt": "X", "a.txt": "A", "b.txt": "B"}
	write(t, filepath.Join(d.src, "x.txt"), "x")
	write(t, filepath.Join(d.src, "y.txt"), "x")
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	write(t, filepath.Join(d.src, "b.txt"), "google bbbb")
	d.mustRun()
	os.Remove(filepath.Join(d.src, "y.txt"))
	write(t, filepath.Join(d.src, "x.txt"), "x v2")
	os.Remove(filepath.Join(d.src, "b.txt"))
	os.Rename(filepath.Join(d.src, "a.txt"), filepath.Join(d.src, "b.txt"))
	f.ids["b.txt"] = "A"
	write(t, filepath.Join(d.src, "b.txt"), "google a v2")
	d.mustRun()
	d.gone("y.txt")
	d.gone("a.txt")
	d.has("x.txt", "x v2")
	d.has("b.txt", "google a v2")
	d.deletedOnce("b", "google bbbb")
	d.noKept()
	d.idle()
}

// A file renamed into a group and edited the same night is fetched anew and
// its old name not kept.
func TestRenameIntoGroupEdited(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"a.txt": "Y"}
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	f.add("r.txt", "X1", "x1", t0)
	f.add("r.txt", "X2", "x2", t0)
	d.mustRun()
	f.drop("X1")
	os.Remove(filepath.Join(d.src, "a.txt"))
	f.add("r.txt", "Y", "google a v2", t0.Add(time.Hour))
	d.mustRun()
	d.gone("a.txt")
	d.has("r~1.txt", "google a v2")
	d.deletedOnce("r~1", "x1")
	d.noKept()
	d.idle()
}

// A file shared as a plain name and as a group member that loses the plain
// name is not moved back every night.
func TestSameIDPlainAndMemberDropped(t *testing.T) {
	d, f := newDupes(t)
	f.ids = map[string]string{"y.txt": "X"}
	write(t, filepath.Join(d.src, "y.txt"), "x")
	os.Chtimes(filepath.Join(d.src, "y.txt"), t0, t0)
	f.add("r.txt", "X", "x", t0)
	f.add("r.txt", "R", "r", t0)
	d.mustRun()
	os.Remove(filepath.Join(d.src, "y.txt"))
	d.mustRun()
	d.gone("y.txt")
	d.noKept()
	d.idle()
}

// historyOf returns the history lines beside manifest, split into fields,
// failing on a line that is not one record.
func historyOf(t *testing.T, manifest string) [][]string {
	t.Helper()
	var lines [][]string
	for l := range strings.Lines(read(t, filepath.Join(filepath.Dir(manifest), "history.tsv"))) {
		f := strings.Split(strings.TrimSuffix(l, "\n"), "\t")
		if len(f) < 6 || len(f) > 7 {
			t.Fatalf("history line %q has %d fields", l, len(f))
		}
		lines = append(lines, f)
	}
	return lines
}

// hasHistory checks that history holds a line with action and the fields
// from want onwards (ID, hash, names) after the time and part.
func hasHistory(t *testing.T, lines [][]string, part, action string, want ...string) {
	t.Helper()
	for _, l := range lines {
		if l[1] == part && l[2] == action && len(l) == 3+len(want) && slices.Equal(l[3:], want) {
			return
		}
	}
	t.Errorf("history lacks %s %s %q:\n%q", part, action, want, lines)
}

// runTotals checks that the last run line of part has the totals of the done
// line in logs.
func runTotals(t *testing.T, lines [][]string, part, logs string) {
	t.Helper()
	_, done, _ := strings.Cut(logs, part+": done: ")
	done, _, _ = strings.Cut(done, "\n")
	var kv []string
	for _, c := range strings.Split(done, ", ") {
		n, name, _ := strings.Cut(c, " ")
		kv = append(kv, name+"="+n)
	}
	if l := lines[len(lines)-1]; l[1] != part || !strings.HasPrefix(l[5], strings.Join(kv, " ")+" kept=") {
		t.Errorf("run line %q, want %q", l, kv)
	}
}

// checkHistory checks that the history beside manifest, unless it cannot be
// written, ends with a run line that says how the run ended and counts each
// action line of the run.
func checkHistory(t *testing.T, ctx context.Context, manifest string, err error) {
	t.Helper()
	if err != nil && strings.Contains(err.Error(), "history") {
		return
	}
	h := historyOf(t, manifest)
	i := len(h) - 2
	for i >= 0 && h[i][2] != "run" {
		i--
	}
	n := map[string]int{}
	for _, l := range h[i+1 : len(h)-1] {
		n[l[2]]++
	}
	status := map[bool]string{true: "ok", false: "failed"}[err == nil]
	if errors.Is(ctx.Err(), context.Canceled) {
		status = "stopped"
	}
	for kv := range strings.FieldsSeq(h[len(h)-1][5]) {
		if k, v, _ := strings.Cut(kv, "="); k != "unchanged" && v != strconv.Itoa(n[k]) {
			t.Errorf("%s=%s but %d %s lines", k, v, n[k], k)
		}
	}
	if l := h[len(h)-1]; l[2] != "run" || l[3] != status {
		t.Errorf("run line %q, want %s", l, status)
	}
}

// Every action that bumps a count is a history line, with the names quoted;
// the run line repeats the totals.
func TestDriveHistory(t *testing.T) {
	d, f := newDupes(t)
	odd := "q\tx.txt"
	f.ids = map[string]string{"a.txt": "A", "b.txt": "B", "c.txt": "C", "c2.txt": "C", "d.txt": "D", "q␉x.txt": "T\t\n", "e.txt": "E"}
	for _, n := range []string{"a.txt", "b.txt", "c.txt", "d.txt", odd} {
		write(t, filepath.Join(d.src, n), "google "+n)
	}
	d.mustRun()
	h := historyOf(t, d.mf)
	hasHistory(t, h, "drive", "new", `"T\t\n"`, hash([]byte("google "+odd)), `"q␉x.txt"`)
	runTotals(t, h, "drive", d.logs)
	sameSizeEdit(t, filepath.Join(d.dir, "a.txt"), "GOOGLE a.txt")
	write(t, filepath.Join(d.src, "b.txt"), "google b.txt v2")
	os.Rename(filepath.Join(d.src, "c.txt"), filepath.Join(d.src, "c2.txt"))
	os.Remove(filepath.Join(d.src, "d.txt"))
	write(t, filepath.Join(d.src, "e.txt"), "google e.txt")
	os.Chmod(filepath.Join(d.src, "e.txt"), 0)
	t.Cleanup(func() { os.Chmod(filepath.Join(d.src, "e.txt"), 0o600) })
	if err := d.run(); err == nil {
		t.Fatal("want a download error")
	}
	h = historyOf(t, d.mf)
	hasHistory(t, h, "drive", "kept", `"A"`, hash([]byte("GOOGLE a.txt")), `"a.txt"`, strconv.Quote(keptIn(t, d.dir, "a")[0][len(d.dir)+1:]))
	hasHistory(t, h, "drive", "updated", `"B"`, hash([]byte("google b.txt v2")), `"b.txt"`)
	hasHistory(t, h, "drive", "renamed", `"C"`, hash([]byte("google c.txt")), `"c.txt"`, `"c2.txt"`)
	hasHistory(t, h, "drive", "failed", `"E"`, "-", `"e.txt"`)
	runTotals(t, h, "drive", d.logs)
	// rclone deletes nothing in a run with a failed download.
	os.Chmod(filepath.Join(d.src, "e.txt"), 0o600)
	d.mustRun()
	h = historyOf(t, d.mf)
	hasHistory(t, h, "drive", "deleted", `"D"`, hash([]byte("google d.txt")), `"d.txt"`, `"d-deleted-2026-11-23.txt"`)
	runTotals(t, h, "drive", d.logs)
}

// A history that cannot be written fails the run but not the backup.
func TestHistoryWriteFailure(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	os.Mkdir(filepath.Join(filepath.Dir(d.mf), "history.tsv"), 0o700)
	if err := d.run(); err == nil || !strings.Contains(err.Error(), "history") {
		t.Errorf("want a history error, got %v", err)
	}
	d.has("a.txt", "google")
	if !strings.Contains(read(t, d.mf), "  a.txt\n") || strings.Contains(d.logs, "a.txt") {
		t.Errorf("manifest not written or log names files:\n%s", d.logs)
	}
	dir := t.TempDir()
	mf := filepath.Join(t.TempDir(), "manifest")
	os.Mkdir(filepath.Join(filepath.Dir(mf), "history.tsv"), 0o700)
	if err := runManifest(t, context.Background(), &fakeAPI{people: []string{contact("c1", "One")}}, dir, mf); err == nil || !strings.Contains(err.Error(), "history") {
		t.Errorf("contacts: want a history error, got %v", err)
	}
	if !strings.Contains(read(t, mf), "  c1.vcf\n") {
		t.Error("contacts manifest not written")
	}
}

// A rename is recorded once done, whatever then becomes of the file.
func TestHistoryRenameThenEditOrFail(t *testing.T) {
	for _, fail := range []bool{false, true} {
		d, f := newDupes(t)
		f.ids = map[string]string{"c.txt": "C", "c2.txt": "C"}
		write(t, filepath.Join(d.src, "c.txt"), "google c")
		d.mustRun()
		os.Rename(filepath.Join(d.src, "c.txt"), filepath.Join(d.src, "c2.txt"))
		write(t, filepath.Join(d.src, "c2.txt"), "google c v2")
		action := "updated"
		if fail {
			os.Chmod(filepath.Join(d.src, "c2.txt"), 0)
			t.Cleanup(func() { os.Chmod(filepath.Join(d.src, "c2.txt"), 0o600) })
			action = "failed"
		}
		d.run()
		h := historyOf(t, d.mf)
		hasHistory(t, h, "drive", "renamed", `"C"`, hash([]byte("google c")), `"c.txt"`, `"c2.txt"`)
		if l := h[len(h)-2]; l[2] != action || l[5] != `"c2.txt"` {
			t.Errorf("fail=%v: last action %q, want %s c2.txt", fail, l, action)
		}
	}
}

// A file edited before the run and again by a peer during rclone sync is kept
// twice.
func TestDriveEditedTwice(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google a")
	d.mustRun()
	write(t, filepath.Join(d.dir, "a.txt"), "edit before")
	real := rcloneBin
	wrapRclone(t, " sync ", "echo peer > "+filepath.Join(d.dir, "a.txt"), "")
	d.mustRun()
	rcloneBin = real
	d.has("a.txt", "google a")
	var got []string
	for _, k := range keptIn(t, d.dir, "a") {
		got = append(got, read(t, k))
	}
	if slices.Sort(got); !slices.Equal(got, []string{"edit before", "peer\n"}) {
		t.Errorf("kept copies %q", got)
	}
	d.idle()
}

// A history that rejects writes, and one a killed run left mid-line.
func TestHistoryDamaged(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	if err := os.Symlink("/dev/full", filepath.Join(filepath.Dir(d.mf), "history.tsv")); err != nil {
		t.Fatal(err)
	}
	if err := d.run(); err == nil || !strings.Contains(err.Error(), "history: write") {
		t.Errorf("want a history error, got %v", err)
	}
	d.has("a.txt", "google")
	d = newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	write(t, filepath.Join(filepath.Dir(d.mf), "history.tsv"), "2026-11-23T00:15:00Z\tdrive\trun\tok\t-\tnew=1 upd")
	d.mustRun()
	if h := read(t, filepath.Join(filepath.Dir(d.mf), "history.tsv")); !strings.Contains(h, "new=1 upd\n") || strings.Count(h, "\n") != 3 {
		t.Errorf("history after a partial line:\n%q", h)
	}
}

// A run that cannot list the mirror at its end counts nothing unchanged.
func TestHistoryUncheckedRun(t *testing.T) {
	d := newDrive(t)
	write(t, filepath.Join(d.src, "a.txt"), "google")
	d.mustRun()
	mark := filepath.Join(t.TempDir(), "listed")
	wrapRclone(t, " --hash ", "[ -e "+mark+" ] && exit 1", "touch "+mark)
	if err := d.run(); err == nil {
		t.Fatal("want a listing error")
	}
	if h := historyOf(t, d.mf); !strings.Contains(h[len(h)-1][5], " unchanged=0 ") {
		t.Errorf("run line %q", h[len(h)-1])
	}
}
