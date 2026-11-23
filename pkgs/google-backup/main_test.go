package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"
)

const alice = `{
  "resourceName": "people/c1",
  "names": [{"displayName": "Alice A, Jr.", "familyName": "Doe;Smith", "givenName": "Alice"}],
  "emailAddresses": [
    {"value": "a@example.com", "type": "home", "metadata": {"primary": true}},
    {"value": "alice@work.example", "type": "work"}
  ],
  "phoneNumbers": [{"value": "+370 600 00000", "type": "mobile"}],
  "addresses": [{"type": "home", "streetAddress": "Gatvė 1\nButas 2", "city": "Vilnius", "country": "LT"}],
  "organizations": [{"name": "ACME", "title": "Boss"}],
  "birthdays": [{"date": {"month": 3, "day": 15}}],
  "events": [{"type": "anniversary", "date": {"year": 2010, "month": 6, "day": 1}}],
  "biographies": [{"value": "likes ; and , and \\"}, {"value": "a long note that goes on and on past the seventy-five octet line limit of vCard"}],
  "memberships": [
    {"contactGroupMembership": {"contactGroupResourceName": "contactGroups/friends"}},
    {"contactGroupMembership": {"contactGroupResourceName": "contactGroups/myContacts"}}
  ],
  "photos": [{"url": "https://example.com/default.jpg", "default": true}, {"url": "https://example.com/a.jpg"}]
}`

func TestRender(t *testing.T) {
	var p person
	if err := json.Unmarshal([]byte(alice), &p); err != nil {
		t.Fatal(err)
	}
	got := string(render(p, map[string]string{"contactGroups/friends": "Friends, close"}, &photo{"https://example.com/a.jpg", "JPEG", "AAEC", ""}))
	for _, want := range []string{
		"BEGIN:VCARD\r\nVERSION:3.0\r\n",
		"\r\nFN:Alice A\\, Jr.\r\n",
		"\r\nN:Doe\\;Smith;Alice;;;\r\n",
		"\r\nUID:people/c1\r\n",
		"\r\nEMAIL;TYPE=INTERNET;TYPE=home;TYPE=pref:a@example.com\r\nEMAIL;TYPE=INTERNET;TYPE=work:alice@work.example\r\n",
		"\r\nTEL;TYPE=mobile:+370 600 00000\r\n",
		"\r\nADR;TYPE=home:;;Gatvė 1\\nButas 2;Vilnius;;;LT\r\n",
		"\r\nORG:ACME;\r\n",
		"\r\nTITLE:Boss\r\n",
		"\r\nBDAY:--0315\r\n",
		"\r\nX-ANNIVERSARY:2010-06-01\r\n",
		"\r\nNOTE:likes \\; and \\, and \\\\\r\n",
		"\r\nCATEGORIES:Friends\\, close\r\n",
		"\r\nPHOTO;ENCODING=b;TYPE=JPEG:AAEC\r\nX-PHOTO-SOURCE:https://example.com/a.jpg\r\n",
		"END:VCARD\r\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	for _, l := range strings.Split(got, "\r\n") {
		if len(l) > 75 {
			t.Errorf("unfolded line %q", l)
		}
	}
	if strings.Contains(got, "default.jpg") || strings.Contains(got, "myContacts") {
		t.Errorf("placeholder photo or system group rendered:\n%s", got)
	}
}

func TestFold(t *testing.T) {
	line := "NOTE:x" + strings.Repeat("ž", 100)
	folded := fold(line)
	for _, l := range strings.Split(strings.TrimSuffix(folded, "\r\n"), "\r\n") {
		if len(l) > 75 || !utf8.ValidString(l) {
			t.Errorf("bad folded line %q", l)
		}
	}
	if strings.ReplaceAll(strings.TrimSuffix(folded, "\r\n"), "\r\n ", "") != line {
		t.Errorf("unfolding does not give back the line")
	}
}

// fakeAPI serves people as pages of two plus one user contact group.
type fakeAPI struct{ people []string }

func (f *fakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/contactGroups":
		w.Write([]byte(`{"contactGroups": [{"resourceName": "contactGroups/friends", "formattedName": "Friends", "groupType": "USER_CONTACT_GROUP"}, {"resourceName": "contactGroups/myContacts", "formattedName": "myContacts", "groupType": "SYSTEM_CONTACT_GROUP"}]}`))
	case "/people/me/connections":
		start := 0
		if tok := r.URL.Query().Get("pageToken"); tok != "" {
			start = int(tok[0] - '0')
		}
		end := min(start+2, len(f.people))
		next := ""
		if end < len(f.people) {
			next = string(rune('0' + end))
		}
		w.Write([]byte(`{"connections": [` + strings.Join(f.people[start:end], ",") + `], "nextPageToken": "` + next + `"}`))
	default:
		http.NotFound(w, r)
	}
}

func contact(id, name string) string {
	return `{"resourceName": "people/` + id + `", "names": [{"displayName": "` + name + `"}]}`
}

// run syncs dir with the manifest kept beside it.
func run(t *testing.T, api *fakeAPI, dir string) error {
	t.Helper()
	return runManifest(t, context.Background(), api, dir, dir+".manifest")
}

func runManifest(t *testing.T, ctx context.Context, api *fakeAPI, dir, manifest string) error {
	t.Helper()
	srv := httptest.NewServer(api)
	defer srv.Close()
	peopleAPI = srv.URL
	err := syncDir(ctx, srv.Client(), dir, manifest)
	checkHistory(t, ctx, manifest, err)
	return err
}

// state maps each file in dir to its inode and mtime.
func state(t *testing.T, dir string) map[string][2]int64 {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	m := map[string][2]int64{}
	for _, e := range ents {
		fi, err := e.Info()
		if err != nil {
			t.Fatal(err)
		}
		m[e.Name()] = [2]int64{int64(fi.Sys().(*syscall.Stat_t).Ino), fi.ModTime().UnixNano()}
	}
	return m
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSync(t *testing.T) {
	dir := t.TempDir()
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three"), contact("c4", "Four"), contact("c5", "Five")}}
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	first := state(t, dir)
	if len(first) != 5 || !strings.Contains(read(t, filepath.Join(dir, "c5.vcf")), "FN:Five") {
		t.Fatalf("pagination: want 5 vCards incl. the last page, got %v", first)
	}

	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	if got := state(t, dir); !maps.Equal(got, first) {
		t.Fatalf("idle run touched files:\nbefore %v\nafter  %v", first, got)
	}

	api.people = []string{contact("c1", "One"), contact("c2", "Two v2"), contact("c4", "Four"), contact("c5", "Five")}
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	got := state(t, dir)
	if _, ok := got["c3.vcf"]; ok || len(copiesIn(t, dir, "-deleted-", "c3")) != 1 {
		t.Error("deleted contact c3 still on disk or not kept as -deleted-")
	}
	if !strings.Contains(read(t, filepath.Join(dir, "c2.vcf")), "FN:Two v2") {
		t.Error("modified contact c2 not rewritten")
	}
	if got["c2.vcf"][0] == first["c2.vcf"][0] {
		t.Error("c2 was rewritten in place, not renamed over")
	}
	for _, f := range []string{"c1.vcf", "c4.vcf", "c5.vcf"} {
		if got[f] != first[f] {
			t.Errorf("unchanged %s was rewritten", f)
		}
	}
	if len(got) != 5 {
		t.Errorf("want exactly 4 vCards and c3's copy (no temp files left), got %v", got)
	}
}

func TestEmptyRemoteKeepsLocal(t *testing.T) {
	dir := t.TempDir()
	api := &fakeAPI{people: []string{contact("c1", "One")}}
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	before := state(t, dir)
	api.people = nil
	if err := run(t, api, dir); err == nil {
		t.Fatal("empty address book over a non-empty mirror must fail")
	}
	if got := state(t, dir); !maps.Equal(got, before) {
		t.Fatalf("empty remote touched files: %v -> %v", before, got)
	}
}

func TestAPIErrorFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, `{"error": {"message": "nope"}}`, http.StatusForbidden)
	}))
	defer srv.Close()
	peopleAPI = srv.URL
	if err := syncDir(context.Background(), srv.Client(), t.TempDir(), filepath.Join(t.TempDir(), "manifest")); err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("want an error carrying the API message, got %v", err)
	}
}

func renderJSON(t *testing.T, js string) string {
	t.Helper()
	var p person
	if err := json.Unmarshal([]byte(js), &p); err != nil {
		t.Fatal(err)
	}
	return string(render(p, nil, nil))
}

func TestSingleNameAndFN(t *testing.T) {
	got := renderJSON(t, `{"resourceName": "people/c1", "names": [
		{"displayName": "First", "givenName": "First"},
		{"displayName": "Second", "givenName": "Second", "metadata": {"primary": true}}]}`)
	if strings.Count(got, "\r\nN:") != 1 || strings.Count(got, "\r\nFN:") != 1 ||
		!strings.Contains(got, "\r\nN:;Second;;;\r\n") || !strings.Contains(got, "\r\nFN:Second\r\n") {
		t.Errorf("want one N and FN from the primary name:\n%s", got)
	}
	got = renderJSON(t, `{"resourceName": "people/c1", "names": [{"displayName": "A", "givenName": "A"}, {"displayName": "B", "givenName": "B"}]}`)
	if !strings.Contains(got, "\r\nN:;A;;;\r\n") || !strings.Contains(got, "\r\nFN:A\r\n") {
		t.Errorf("without a primary name the first wins:\n%s", got)
	}
	got = renderJSON(t, `{"resourceName": "people/c1", "names": [{"displayName": "Only Display"}]}`)
	if !strings.Contains(got, "\r\nN:Only Display;;;;\r\n") || !strings.Contains(got, "\r\nFN:Only Display\r\n") {
		t.Errorf("displayName-only contact needs N:\n%s", got)
	}
}

func TestBirthdays(t *testing.T) {
	got := renderJSON(t, `{"resourceName": "people/c1", "birthdays": [
		{"date": {"year": 1990}}, {"date": {"year": 1990, "month": 2, "day": 3}}, {"date": {"month": 4, "day": 5}}]}`)
	if strings.Contains(got, "BDAY:1990\r\n") || strings.Contains(got, "-00") || strings.Count(got, "BDAY") != 2 ||
		!strings.Contains(got, "BDAY:1990-02-03\r\n") || !strings.Contains(got, "BDAY:--0405\r\n") {
		t.Errorf("year-only BDAY must be omitted, the rest kept:\n%s", got)
	}
}

func TestURIsNotEscaped(t *testing.T) {
	var p person
	json.Unmarshal([]byte(`{"resourceName": "people/c1", "urls": [{"value": "https://e.com/a,b;c"}]}`), &p)
	got := string(render(p, nil, &photo{"https://e.com/p,q;r.jpg", "PNG", "AAEC", ""}))
	for _, want := range []string{"\r\nURL:https://e.com/a,b;c\r\n", "\r\nX-PHOTO-SOURCE:https://e.com/p,q;r.jpg\r\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
}

func TestControlChars(t *testing.T) {
	got := renderJSON(t, "{\"resourceName\": \"people/c1\", \"biographies\": [{\"value\": \"a\\u0001b\\u001fc\\u007fd\\re\\r\\nf\\tg\"}]}")
	if !strings.Contains(got, "\r\nNOTE:abcd\\ne\\nf\tg\r\n") {
		t.Errorf("controls not dropped, bare CR not a line break:\n%q", got)
	}
}

func TestIMPPService(t *testing.T) {
	got := renderJSON(t, `{"resourceName": "people/c1", "imClients": [
		{"username": "a", "protocol": "jabber"}, {"username": "b"}]}`)
	if !strings.Contains(got, "\r\nIMPP;X-SERVICE-TYPE=jabber:a\r\n") || !strings.Contains(got, "\r\nIMPP:b\r\n") {
		t.Errorf("X-SERVICE-TYPE only with a protocol:\n%s", got)
	}
}

func TestSystemGroupsExcluded(t *testing.T) {
	dir := t.TempDir()
	api := &fakeAPI{people: []string{`{"resourceName": "people/c1", "names": [{"displayName": "One"}], "memberships": [
		{"contactGroupMembership": {"contactGroupResourceName": "contactGroups/friends"}},
		{"contactGroupMembership": {"contactGroupResourceName": "contactGroups/myContacts"}}]}`}}
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(dir, "c1.vcf")); !strings.Contains(got, "\r\nCATEGORIES:Friends\r\n") {
		t.Errorf("want only the user group:\n%s", got)
	}
}

func fastBackoff(t *testing.T) {
	old := backoff
	backoff = []time.Duration{time.Millisecond, time.Millisecond}
	t.Cleanup(func() { backoff = old })
}

func TestRetry(t *testing.T) {
	fastBackoff(t)
	for _, code := range []int{http.StatusServiceUnavailable, http.StatusTooManyRequests} {
		var n atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if n.Add(1) == 1 {
				http.Error(w, `{}`, code)
				return
			}
			w.Write([]byte(`{"a": 1}`))
		}))
		peopleAPI = srv.URL
		var v struct{ A int }
		err := get(context.Background(), srv.Client(), "/x", nil, &v)
		srv.Close()
		if err != nil || v.A != 1 || n.Load() != 2 {
			t.Errorf("%d then 200: err=%v v=%v attempts=%d", code, err, v, n.Load())
		}
	}

	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		http.Error(w, `{}`, http.StatusInternalServerError)
	}))
	defer srv.Close()
	peopleAPI = srv.URL
	if err := get(context.Background(), srv.Client(), "/x", nil, new(struct{})); err == nil || n.Load() != 3 {
		t.Errorf("persistent 500: want failure after 3 attempts, got err=%v attempts=%d", err, n.Load())
	}

	// A dropped connection is a transport error: retried, then failing.
	n.Store(0)
	dropper := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	}))
	defer dropper.Close()
	peopleAPI = dropper.URL
	if err := get(context.Background(), dropper.Client(), "/x", nil, new(struct{})); err == nil || n.Load() != 3 {
		t.Errorf("dropped connection: want 3 attempts then failure, got err=%v attempts=%d", err, n.Load())
	}

	n.Store(0)
	forbidden := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		http.Error(w, `{}`, http.StatusForbidden)
	}))
	defer forbidden.Close()
	peopleAPI = forbidden.URL
	if err := get(context.Background(), forbidden.Client(), "/x", nil, new(struct{})); err == nil || n.Load() != 1 {
		t.Errorf("403 must not be retried: err=%v attempts=%d", err, n.Load())
	}
}

func recv(t *testing.T, ch <-chan authResult) authResult {
	t.Helper()
	select {
	case res := <-ch:
		return res
	case <-time.After(5 * time.Second):
		t.Fatal("no callback result")
		return authResult{}
	}
}

func TestAuthDenied(t *testing.T) {
	results := make(chan authResult, 1)
	srv := httptest.NewServer(callback("st", results))
	defer srv.Close()
	for _, u := range []string{"/favicon.ico", "/?state=wrong&error=x"} {
		http.Get(srv.URL + u)
	}
	select {
	case res := <-results:
		t.Fatalf("unrelated request produced a result: %v", res)
	default:
	}
	http.Get(srv.URL + "/?state=st&error=access_denied")
	if res := recv(t, results); res.err == nil || !strings.Contains(res.err.Error(), "access_denied") {
		t.Errorf("want the denial error, got %+v", res)
	}
	results = make(chan authResult, 1)
	srv2 := httptest.NewServer(callback("st", results))
	defer srv2.Close()
	http.Get(srv2.URL + "/?state=st&code=abc")
	if res := recv(t, results); res.err != nil || res.code != "abc" {
		t.Errorf("want code, got %+v", res)
	}
}

func TestRetryAfter(t *testing.T) {
	fastBackoff(t)
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) == 1 {
			w.Header().Set("Retry-After", "1")
			http.Error(w, `{}`, http.StatusTooManyRequests)
			return
		}
		w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	peopleAPI = srv.URL
	start := time.Now()
	if err := get(context.Background(), srv.Client(), "/x", nil, new(struct{})); err != nil || time.Since(start) < time.Second {
		t.Errorf("Retry-After not honoured: err=%v after %v", err, time.Since(start))
	}
}

// bearer mimics oauth2.Transport: every request it sends carries a token.
type bearer struct{ base http.RoundTripper }

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer SECRET")
	return b.base.RoundTrip(r)
}

// fakePhotos serves bodies by path (or a status), counting requests and
// recording the last path and query and any Authorization seen.
type fakePhotos struct {
	mu     sync.Mutex
	bodies map[string][]byte
	status map[string]int
	hits   atomic.Int32
	auth   []string
	last   string
}

func (f *fakePhotos) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.hits.Add(1)
	f.mu.Lock()
	if a := r.Header.Get("Authorization"); a != "" {
		f.auth = append(f.auth, a)
	}
	f.last = r.URL.RequestURI()
	st, b := f.status[r.URL.Path], f.bodies[r.URL.Path]
	f.mu.Unlock()
	if st != 0 {
		http.Error(w, "x", st)
		return
	}
	if b == nil {
		http.NotFound(w, r)
		return
	}
	w.Write(b)
}

// runAuth is run with an API client that attaches a bearer token, as in production.
func runAuth(t *testing.T, api *fakeAPI, dir string) error {
	t.Helper()
	srv := httptest.NewServer(api)
	defer srv.Close()
	peopleAPI = srv.URL
	return syncDir(context.Background(), &http.Client{Transport: bearer{srv.Client().Transport}}, dir, dir+".manifest")
}

func photoContact(id, name, url string) string {
	return `{"resourceName": "people/` + id + `", "names": [{"displayName": "` + name + `"}], "photos": [{"url": "` + url + `"}]}`
}

// jpeg is a long enough body (many folded lines) that sniffs as JPEG.
var jpeg = append([]byte{0xff, 0xd8, 0xff, 0xe0}, []byte(strings.Repeat("jpegdata\x00\xff", 500))...)

// decodePhotos returns the decoded PHOTO bytes, TYPEs and X-PHOTO-SOURCEs of a vCard.
func decodePhotos(t *testing.T, card string) (photos [][]byte, types, sources []string) {
	t.Helper()
	for _, l := range strings.Split(strings.TrimSuffix(strings.NewReplacer("\r\n ", "", "\r\n\t", "").Replace(card), "\r\n"), "\r\n") {
		head, val, _ := strings.Cut(l, ":")
		switch name, params, _ := strings.Cut(head, ";"); name {
		case "PHOTO":
			if !strings.HasPrefix(params, "ENCODING=b;TYPE=") {
				t.Fatalf("PHOTO params %q", params)
			}
			b, err := base64.StdEncoding.Strict().DecodeString(val)
			if err != nil {
				t.Fatalf("PHOTO base64: %v", err)
			}
			photos, types = append(photos, b), append(types, strings.TrimPrefix(params, "ENCODING=b;TYPE="))
		case "X-PHOTO-SOURCE":
			sources = append(sources, val)
		}
	}
	return
}

func TestPhotoEmbedAndIncremental(t *testing.T) {
	png := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0, 1, 2, 0xff, 0xfe}, 3000)...)
	gif := append([]byte("GIF89a"), bytes.Repeat([]byte{7, 0xc3, 0xa9}, 101)...)
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg, "/b": jpeg, "/p": png, "/g": gif}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	long := ps.URL + "/a?" + strings.Repeat("k=v&", 40) + "z=ž"
	api := &fakeAPI{people: []string{
		photoContact("c1", "One", long),
		`{"resourceName": "people/c2", "names": [{"displayName": "Two"}], "photos": [{"url": "` + ps.URL + `/default", "default": true}]}`,
		photoContact("c3", "Three", ps.URL+"/p"),
		photoContact("c4", "Four", ps.URL+"/g"),
	}}
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	if fp.hits.Load() != 3 {
		t.Fatalf("want three downloads (default photo skipped), got %d", fp.hits.Load())
	}
	for id, want := range map[string]struct {
		b        []byte
		typ, src string
	}{"c1": {jpeg, "JPEG", long}, "c3": {png, "PNG", ps.URL + "/p"}, "c4": {gif, "GIF", ps.URL + "/g"}} {
		card := read(t, filepath.Join(dir, id+".vcf"))
		for _, l := range strings.Split(card, "\r\n") {
			if len(l) > 75 {
				t.Errorf("%s: physical line of %d octets", id, len(l))
			}
		}
		ph, ty, src := decodePhotos(t, card)
		if len(ph) != 1 || !bytes.Equal(ph[0], want.b) || ty[0] != want.typ || len(src) != 1 || src[0] != want.src {
			t.Errorf("%s: photos=%d type=%v src=%q", id, len(ph), ty, src)
		}
	}
	if strings.Contains(read(t, filepath.Join(dir, "c2.vcf")), "PHOTO") {
		t.Error("default photo rendered")
	}
	if len(fp.auth) != 0 {
		t.Fatalf("photo host saw credentials: %v", fp.auth)
	}

	first := state(t, dir)
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	if fp.hits.Load() != 3 || !maps.Equal(state(t, dir), first) {
		t.Errorf("idle run: photo requests=%d, files touched=%v", fp.hits.Load()-3, !maps.Equal(state(t, dir), first))
	}

	api.people[0] = photoContact("c1", "One", ps.URL+"/b")
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	got := state(t, dir)
	if fp.hits.Load() != 4 || got["c1.vcf"] == first["c1.vcf"] || !strings.Contains(read(t, filepath.Join(dir, "c1.vcf")), "X-PHOTO-SOURCE:"+ps.URL+"/b\r\n") {
		t.Errorf("URL change: want one more download and a rewrite, got hits=%d", fp.hits.Load())
	}
	if got["c2.vcf"] != first["c2.vcf"] || got["c3.vcf"] != first["c3.vcf"] {
		t.Error("unrelated contact rewritten")
	}
}

func TestNoBearerOnRedirect(t *testing.T) {
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	redir := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, ps.URL+"/a", http.StatusFound)
	}))
	defer redir.Close()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", redir.URL+"/r")}}, t.TempDir()); err != nil || fp.hits.Load() != 1 || len(fp.auth) != 0 {
		t.Errorf("err=%v hits=%d credentials=%v", err, fp.hits.Load(), fp.auth)
	}
}

func TestSizedURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://lh3.googleusercontent.com/a/default-user=s100":   "https://lh3.googleusercontent.com/a/default-user=s720",
		"https://lh3.googleusercontent.com/a/x=s100-p?k=v":        "https://lh3.googleusercontent.com/a/x=s720?k=v",
		"https://lh3.googleusercontent.com/-T/AAA/s100/photo.jpg": "https://lh3.googleusercontent.com/-T/AAA/s100/photo.jpg?sz=720",
		"https://lh3.googleusercontent.com/p.jpg?sz=50&k=v":       "https://lh3.googleusercontent.com/p.jpg?k=v&sz=720",
		"https://lh3.googleusercontent.com/a%2Fb=s64":             "https://lh3.googleusercontent.com/a%2Fb=s720",
	} {
		if got, err := sizedURL(in); err != nil || got != want {
			t.Errorf("sizedURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	fp := &fakePhotos{bodies: map[string][]byte{"/a=s720": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/a=s100")}}, t.TempDir()); err != nil || fp.last != "/a=s720" {
		t.Errorf("err=%v requested %q", err, fp.last)
	}
}

func TestPhotoErrors(t *testing.T) {
	fastBackoff(t)
	png := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 20)...)
	fp := &fakePhotos{bodies: map[string][]byte{
		"/ok":   jpeg,
		"/text": []byte("<html>not an image</html>"),
		"/big":  append([]byte{0xff, 0xd8, 0xff}, make([]byte, maxPhotoBytes)...),
		"/png":  png,
	}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/ok")}}, dir); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"/text", "/big", "/missing"} {
		api := &fakeAPI{people: []string{photoContact("c1", "One "+bad, ps.URL+bad), photoContact("c3", "Three", ps.URL+"/ok")}}
		err := runAuth(t, api, dir)
		if err == nil || !strings.Contains(err.Error(), "people/c1") || strings.Contains(err.Error(), ps.URL) {
			t.Fatalf("%s: want an error naming c1 but not the URL, got %v", bad, err)
		}
		card := read(t, filepath.Join(dir, "c1.vcf"))
		if ph, _, src := decodePhotos(t, card); len(ph) != 1 || !bytes.Equal(ph[0], jpeg) || src[0] != ps.URL+"/ok" {
			t.Errorf("%s: old photo and source must survive a failed fetch", bad)
		}
		if !strings.Contains(card, "FN:One "+bad) || !strings.Contains(read(t, filepath.Join(dir, "c3.vcf")), "FN:Three") {
			t.Errorf("%s: field change or other contact not written", bad)
		}
		os.Remove(filepath.Join(dir, "c3.vcf"))
	}

	// A new contact with a permanently failing photo is still written, without it.
	nd := t.TempDir()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/missing")}}, nd); err == nil {
		t.Error("failed photo must fail the run")
	}
	if got := read(t, filepath.Join(nd, "c1.vcf")); !strings.Contains(got, "FN:One") || strings.Contains(got, "PHOTO;") {
		t.Errorf("new contact: want a card without photo, got\n%.200s", got)
	}

	// A transient 503 is retried; with the old source kept, the next night retries.
	fp.status = map[string]int{"/ok2": 503}
	fp.bodies["/ok2"] = jpeg
	hits := fp.hits.Load()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/ok2")}}, dir); err == nil || fp.hits.Load()-hits != 3 {
		t.Errorf("persistent 503: err=%v attempts=%d", err, fp.hits.Load()-hits)
	}
	fp.mu.Lock()
	delete(fp.status, "/ok2")
	fp.mu.Unlock()
	if err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/ok2")}}, dir); err != nil {
		t.Fatal(err)
	}
	if _, _, src := decodePhotos(t, read(t, filepath.Join(dir, "c1.vcf"))); len(src) != 1 || src[0] != ps.URL+"/ok2" {
		t.Errorf("recovered fetch not stored: %v", src)
	}
}

func TestPhotoRemovedInGoogle(t *testing.T) {
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	api := &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/a")}}
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	first := state(t, dir)
	api.people = []string{`{"resourceName": "people/c1", "names": [{"displayName": "One"}], "photos": [{"url": "` + ps.URL + `/a", "default": true}]}`}
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(read(t, filepath.Join(dir, "c1.vcf")), "PHOTO") || state(t, dir)["c1.vcf"] == first["c1.vcf"] {
		t.Fatal("removed photo still embedded or file not rewritten")
	}
	second := state(t, dir)
	if err := runAuth(t, api, dir); err != nil || !maps.Equal(state(t, dir), second) || fp.hits.Load() != 1 {
		t.Errorf("after removal: not idle (hits=%d, err=%v)", fp.hits.Load(), err)
	}
}

// An existing file the tool did not write exactly (or damaged) is reused only
// when its photo decodes to an image of the declared type.
func TestPhotoReuseValidation(t *testing.T) {
	src := "https://h/p"
	b64 := base64.StdEncoding.EncodeToString(jpeg)
	good := string(render(person{ResourceName: "people/c1"}, nil, &photo{src, "JPEG", b64, ""}))
	for name, c := range map[string]struct {
		card  string
		reuse bool
	}{
		"own":           {good, true},
		"tab-fold":      {strings.ReplaceAll(good, "\r\n ", "\r\n\t"), true},
		"LF":            {strings.ReplaceAll(good, "\r\n", "\n"), false},
		"no-source":     {strings.Replace(good, "X-PHOTO-SOURCE:"+src+"\r\n", "", 1), false},
		"note-mentions": {strings.Replace(good, "X-PHOTO-SOURCE:"+src+"\r\n", "NOTE:X-PHOTO-SOURCE:"+src+"\r\n", 1), false},
		"truncated-b64": {strings.Replace(good, "\r\nX-PHOTO-SOURCE", "\r\n ===\r\nX-PHOTO-SOURCE", 1), false},
		"garbage-b64":   {strings.Replace(good, "TYPE=JPEG:", "TYPE=JPEG:!!!", 1), false},
		"wrong-type":    {strings.Replace(good, "TYPE=JPEG", "TYPE=PNG", 1), false},
		"not-an-image":  {string(render(person{ResourceName: "people/c1"}, nil, &photo{src, "JPEG", base64.StdEncoding.EncodeToString([]byte("hello")), ""})), false},
		"empty":         {"", false},
	} {
		ph := parsePhoto([]byte(c.card))
		if (ph.B64 != "") != c.reuse || (c.reuse && (ph.Source != src || ph.B64 != b64)) {
			t.Errorf("%s: parsePhoto = %+v, want reuse=%v", name, ph, c.reuse)
		}
	}

	// A damaged file with the right source is re-downloaded, not trusted.
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	api := &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/a")}}
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "c1.vcf")
	os.WriteFile(path, []byte(strings.Replace(read(t, path), "TYPE=JPEG:", "TYPE=JPEG:!!!", 1)), 0o600)
	if err := runAuth(t, api, dir); err != nil || fp.hits.Load() != 2 {
		t.Fatalf("err=%v hits=%d", err, fp.hits.Load())
	}
	if ph, _, _ := decodePhotos(t, read(t, path)); len(ph) != 1 || !bytes.Equal(ph[0], jpeg) {
		t.Error("damaged photo not repaired")
	}
}

func TestWithRetryCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	n := 0
	withRetry(ctx, func() (time.Duration, error) { n++; return 0, errors.New("x") })
	if n != 1 {
		t.Errorf("attempts after cancel = %d, want 1", n)
	}
}

func TestPhotoTransportErrorHidesURL(t *testing.T) {
	fastBackoff(t)
	ps := httptest.NewServer(http.NotFoundHandler())
	url := ps.URL + "/secret-token"
	ps.Close()
	err := runAuth(t, &fakeAPI{people: []string{photoContact("c1", "One", url)}}, t.TempDir())
	if err == nil || strings.Contains(err.Error(), "secret-token") || strings.Contains(err.Error(), ps.URL) {
		t.Errorf("want a failure without the photo URL, got %v", err)
	}
}

// captureStderr returns what f writes to os.Stderr.
func captureStderr(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	f()
	os.Stderr = old
	w.Close()
	b, _ := io.ReadAll(r)
	return string(b)
}

// A permanently failing photo fails the first night only; later nights log it.
func TestPhotoFailedMarker(t *testing.T) {
	fastBackoff(t)
	fp := &fakePhotos{bodies: map[string][]byte{"/ok": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	card := filepath.Join(dir, "c1.vcf")
	api := &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/gone")}}

	if err := runAuth(t, api, dir); err == nil || strings.Contains(err.Error(), ps.URL) {
		t.Fatalf("night 1: want an error without the URL, got %v", err)
	}
	if got := read(t, card); !strings.Contains(got, "FN:One") || !strings.Contains(got, "\r\nX-PHOTO-FAILED:"+ps.URL+"/gone\r\n") || strings.Contains(got, "PHOTO;") {
		t.Fatalf("night 1 card:\n%s", got)
	}

	before, hits := state(t, dir), fp.hits.Load()
	var err error
	logged := captureStderr(t, func() { err = runAuth(t, api, dir) })
	if err != nil || !maps.Equal(state(t, dir), before) || fp.hits.Load()-hits != 1 {
		t.Errorf("night 2: err=%v unchanged=%v hits=%d", err, maps.Equal(state(t, dir), before), fp.hits.Load()-hits)
	}
	if !strings.Contains(logged, "1 photo fetches failed again") || strings.Contains(logged, "people/c1") || strings.Contains(logged, ps.URL) {
		t.Errorf("night 2 log: want a count and no name or URL, got %q", logged)
	}

	// A new failing URL is a new first failure.
	api.people = []string{photoContact("c1", "One", ps.URL+"/gone2")}
	if err := runAuth(t, api, dir); err == nil || !strings.Contains(read(t, card), "X-PHOTO-FAILED:"+ps.URL+"/gone2\r\n") {
		t.Errorf("new failing URL: err=%v", err)
	}

	// Recovery embeds the photo and drops the marker.
	fp.mu.Lock()
	fp.bodies["/gone2"] = jpeg
	fp.mu.Unlock()
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	got := read(t, card)
	if ph, _, _ := decodePhotos(t, got); len(ph) != 1 || strings.Contains(got, "X-PHOTO-FAILED") {
		t.Errorf("recovery:\n%.200s", got)
	}

	// Reverting to the still-embedded photo URL drops a stale marker.
	api.people = []string{photoContact("c4", "Four", ps.URL+"/ok")}
	if err := runAuth(t, api, dir); err != nil {
		t.Fatal(err)
	}
	api.people = []string{photoContact("c4", "Four", ps.URL+"/gone")}
	if err := runAuth(t, api, dir); err == nil {
		t.Fatal("c4 must fail")
	}
	api.people = []string{photoContact("c4", "Four", ps.URL+"/ok")}
	if err := runAuth(t, api, dir); err != nil || strings.Contains(read(t, filepath.Join(dir, "c4.vcf")), "FAILED") {
		t.Errorf("revert: err=%v", err)
	}

	// Photo removed in Google drops the marker too.
	api.people = []string{photoContact("c2", "Two", ps.URL+"/gone")}
	runAuth(t, api, dir)
	api.people = []string{`{"resourceName": "people/c2", "names": [{"displayName": "Two"}]}`}
	if err := runAuth(t, api, dir); err != nil || strings.Contains(read(t, filepath.Join(dir, "c2.vcf")), "FAILED") {
		t.Errorf("removed photo: err=%v", err)
	}

	// A transient failure on a first night that then succeeds leaves no trace.
	fp.mu.Lock()
	fp.status = map[string]int{"/t": 503}
	fp.bodies["/t"] = jpeg
	fp.mu.Unlock()
	api.people = []string{photoContact("c3", "Three", ps.URL+"/t")}
	if err := runAuth(t, api, dir); err == nil {
		t.Error("transient night 1 must fail")
	}
	fp.mu.Lock()
	delete(fp.status, "/t")
	fp.mu.Unlock()
	if err := runAuth(t, api, dir); err != nil || strings.Contains(read(t, filepath.Join(dir, "c3.vcf")), "FAILED") {
		t.Errorf("transient recovery: err=%v", err)
	}
}

// keptIn lists the -kept- copies of stem ("" for any) under dir.
func keptIn(t *testing.T, dir, stem string) []string {
	return copiesIn(t, dir, "-kept-", stem)
}

// copiesIn lists the copies of stem ("" for any) tagged tag under dir.
func copiesIn(t *testing.T, dir, tag, stem string) []string {
	t.Helper()
	var k []string
	err := filepath.WalkDir(dir, func(p string, e os.DirEntry, err error) error {
		if err == nil && (strings.HasPrefix(e.Name(), stem+tag) || stem == "" && strings.Contains(e.Name(), tag)) {
			k = append(k, p)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestKeepLocalChanges(t *testing.T) {
	dir := t.TempDir()
	manifest := filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three")}}
	if err := runManifest(t, context.Background(), api, dir, manifest); err != nil {
		t.Fatal(err)
	}
	if got := keptIn(t, dir, "c1"); len(got) != 0 {
		t.Fatalf("first run (no manifest) kept %v", got)
	}
	if !strings.Contains(read(t, manifest), hash([]byte(read(t, filepath.Join(dir, "c1.vcf"))))+"  c1.vcf\n") {
		t.Fatalf("manifest lacks c1:\n%s", read(t, manifest))
	}

	// Same-length edit of c1 with its mtime put back; c3 is edited and then
	// removed from Google; x9 is added on disk; c2 is untouched.
	c1 := filepath.Join(dir, "c1.vcf")
	orig := read(t, c1)
	fi, _ := os.Stat(c1)
	write(t, c1, strings.Replace(orig, "One", "Ona", 1))
	if err := os.Chtimes(c1, fi.ModTime(), fi.ModTime()); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(dir, "x9.vcf"), "ADDED")
	write(t, filepath.Join(dir, "c3.vcf"), "EDITED3")
	api.people = []string{contact("c1", "One"), contact("c2", "Two")}

	var err error
	logs := captureStderr(t, func() { err = runManifest(t, context.Background(), api, dir, manifest) })
	if err != nil {
		t.Fatal(err)
	}
	if read(t, c1) != orig {
		t.Error("edited c1 not rewritten from Google")
	}
	if k := keptIn(t, dir, "c1"); len(k) != 1 || read(t, k[0]) != strings.Replace(orig, "One", "Ona", 1) {
		t.Errorf("edited c1: want one kept copy with the edit, got %v", k)
	}
	if k := keptIn(t, dir, "x9"); len(k) != 1 || read(t, k[0]) != "ADDED" {
		t.Errorf("added x9: want one kept copy with its content, got %v", k)
	}
	if _, err := os.Stat(filepath.Join(dir, "x9.vcf")); !os.IsNotExist(err) {
		t.Error("added x9.vcf not removed after being kept")
	}
	if k := keptIn(t, dir, "c3"); len(k) != 1 || read(t, k[0]) != "EDITED3" {
		t.Errorf("removed-but-edited c3: want one kept copy, got %v", k)
	}
	if k := keptIn(t, dir, "c2"); len(k) != 0 {
		t.Errorf("untouched c2 kept %v", k)
	}
	if !strings.Contains(logs, "contacts: 3 changed on disk since the last run, kept as *-kept-") {
		t.Errorf("count line missing:\n%s", logs)
	}
	if strings.Contains(logs, "x9") || strings.Contains(logs, "EDITED") {
		t.Errorf("log names files or contents:\n%s", logs)
	}
	if m := read(t, manifest); strings.Contains(m, "-kept-") || strings.Contains(m, "x9") || strings.Contains(m, "c3") {
		t.Errorf("manifest lists kept copies or gone vCards:\n%s", m)
	}

	// Kept copies are not vCards: later runs neither remove, re-flag nor count them.
	before := state(t, dir)
	logs = captureStderr(t, func() { err = runManifest(t, context.Background(), api, dir, manifest) })
	if err != nil {
		t.Fatal(err)
	}
	if got := state(t, dir); !maps.Equal(got, before) {
		t.Errorf("second run changed the files:\n%v\n%v", before, got)
	}
	if !strings.Contains(logs, "contacts: 0 changed on disk since the last run\n") || !strings.Contains(logs, "2 vCards in") {
		t.Errorf("kept copies counted or re-flagged:\n%s", logs)
	}

	// Only kept copies on disk: an empty address book is no anomaly. A bare date suffix is not a kept copy.
	only, bare := t.TempDir(), t.TempDir()
	write(t, filepath.Join(only, "c1-kept-2026-11-22-000000.vcf"), "kept")
	write(t, filepath.Join(bare, "c1-2026-11-22-000000.vcf"), "real")
	if err := run(t, &fakeAPI{}, only); err != nil {
		t.Errorf("kept copy counted by the empty-listing guard: %v", err)
	}
	if err := run(t, &fakeAPI{}, bare); err == nil {
		t.Error("vCard with a bare date suffix was taken for a kept copy")
	}
}

// With no manifest, a vCard as Google has it is just recorded; any other is
// kept before being replaced or removed, and lends no photo. Older copies are
// left alone, and the next run changes nothing.
func TestNoManifest(t *testing.T) {
	fixedClock(t)
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir := t.TempDir()
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), photoContact("c3", "Three", ps.URL+"/a")}}
	var p3 person
	if err := json.Unmarshal([]byte(api.people[2]), &p3); err != nil {
		t.Fatal(err)
	}
	tampered := string(render(p3, nil, &photo{ps.URL + "/a", "JPEG", base64.StdEncoding.EncodeToString(append(slices.Clone(jpeg), "tampered"...)), ""}))
	write(t, filepath.Join(dir, "c1.vcf"), renderJSON(t, api.people[0]))
	write(t, filepath.Join(dir, "c2.vcf"), "stale")
	write(t, filepath.Join(dir, "c3.vcf"), tampered)
	write(t, filepath.Join(dir, "x9.vcf"), "local")
	write(t, filepath.Join(dir, "c1-kept-2026-11-01-000000.vcf"), "old kept")
	write(t, filepath.Join(dir, "c2-deleted-2026-11-01.vcf"), "old deleted")
	before := state(t, dir)
	var err error
	logs := captureStderr(t, func() { err = run(t, api, dir) })
	if err != nil {
		t.Fatal(err)
	}
	after := state(t, dir)
	if after["c1.vcf"] != before["c1.vcf"] || read(t, filepath.Join(dir, "c1-kept-2026-11-01-000000.vcf")) != "old kept" || len(keptIn(t, dir, "c1")) != 1 {
		t.Error("c1, as Google has it, was rewritten or kept")
	}
	if read(t, filepath.Join(dir, "c2-deleted-2026-11-01.vcf")) != "old deleted" || len(copiesIn(t, dir, "-deleted-", "")) != 1 {
		t.Error("older -deleted- copy touched, or a new one made")
	}
	for stem, body := range map[string]string{"c2": "stale", "c3": tampered, "x9": "local"} {
		if k := keptIn(t, dir, stem); len(k) != 1 || read(t, k[0]) != body {
			t.Errorf("%s: want one kept copy with its bytes, got %v", stem, k)
		}
	}
	if _, err := os.Lstat(filepath.Join(dir, "x9.vcf")); !errors.Is(err, os.ErrNotExist) {
		t.Error("x9.vcf not moved aside")
	}
	if ph, _, _ := decodePhotos(t, read(t, filepath.Join(dir, "c3.vcf"))); len(ph) != 1 || !bytes.Equal(ph[0], jpeg) || fp.hits.Load() != 1 {
		t.Errorf("c3: photo of an unknown vCard reused (hits=%d)", fp.hits.Load())
	}
	if !strings.Contains(logs, "contacts: 3 changed on disk since the last run, kept as") || !strings.Contains(logs, "done: 0 new, 2 updated, 1 unchanged\n") {
		t.Errorf("logs:\n%s", logs)
	}
	var want string
	for _, c := range []string{"c1", "c2", "c3"} {
		want += hash([]byte(read(t, filepath.Join(dir, c+".vcf")))) + "  " + c + ".vcf\n"
	}
	if got := read(t, dir+".manifest"); got != want {
		t.Errorf("manifest:\n%s\nwant:\n%s", got, want)
	}
	logs = captureStderr(t, func() { err = run(t, api, dir) })
	if got := state(t, dir); err != nil || !maps.Equal(got, after) || !strings.Contains(logs, "contacts: 0 changed on disk") {
		t.Errorf("second run changed files (%v):\n%v\n%v\n%s", err, after, got, logs)
	}
}

// A manifest lost after normal runs loses nothing: an edited vCard and one of
// a contact gone from Google are both kept.
func TestManifestLost(t *testing.T) {
	fixedClock(t)
	dir := t.TempDir()
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three")}}
	for range 2 {
		if err := run(t, api, dir); err != nil {
			t.Fatal(err)
		}
	}
	c2 := read(t, filepath.Join(dir, "c2.vcf"))
	write(t, filepath.Join(dir, "c1.vcf"), "EDITED")
	api.people = []string{contact("c1", "One"), contact("c3", "Three v2")}
	os.Remove(dir + ".manifest")
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	for stem, body := range map[string]string{"c1": "EDITED", "c2": c2} {
		if k := keptIn(t, dir, stem); len(k) != 1 || read(t, k[0]) != body {
			t.Errorf("%s: want one kept copy, got %v", stem, k)
		}
	}
	if !strings.Contains(read(t, filepath.Join(dir, "c3.vcf")), "Three v2") {
		t.Error("c3 not updated")
	}
}

func TestBadManifestFails(t *testing.T) {
	good := strings.Repeat("a", 64) + "  c1.vcf\n"
	for name, m := range map[string]string{
		"truncated line": good[:40],
		"no newline":     good[:len(good)-1],
		"junk":           "hello\n",
		"bad name":       strings.Repeat("a", 64) + "  ../c1.vcf\n",
		"duplicate":      good + good,
	} {
		dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
		write(t, mf, m)
		write(t, filepath.Join(dir, "c1.vcf"), "local")
		api := &fakeAPI{people: []string{contact("c1", "One")}}
		if err := runManifest(t, context.Background(), api, dir, mf); err == nil || !strings.Contains(err.Error(), "manifest") {
			t.Errorf("%s: want manifest error, got %v", name, err)
		}
		if read(t, filepath.Join(dir, "c1.vcf")) != "local" || read(t, mf) != m || len(keptIn(t, dir, "c1")) != 0 {
			t.Errorf("%s: failed run touched files", name)
		}
	}
}

func TestManifestWrittenEvenOnPhotoError(t *testing.T) {
	fastBackoff(t)
	ps := httptest.NewServer(http.NotFoundHandler())
	defer ps.Close()
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/p")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err == nil {
		t.Fatal("want photo error")
	}
	if !strings.Contains(read(t, mf), hash([]byte(read(t, filepath.Join(dir, "c1.vcf"))))+"  c1.vcf\n") {
		t.Errorf("manifest missing the vCard written despite the photo error:\n%s", read(t, mf))
	}
}

// A hard error mid-run records what the run wrote and carries the previous
// entry of the vCards it did not reach (so a pending edit stays detectable).
func TestAbortedRunManifest(t *testing.T) {
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three"), contact("c4", "Four")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	c2 := hash([]byte(read(t, filepath.Join(dir, "c2.vcf"))))
	c3 := hash([]byte(read(t, filepath.Join(dir, "c3.vcf"))))
	c4 := hash([]byte(read(t, filepath.Join(dir, "c4.vcf"))))
	write(t, filepath.Join(dir, "c1.vcf"), "EDITED1")
	write(t, filepath.Join(dir, "c4.vcf"), "EDITED4") // gone from Google; the aborted run never reaches it
	api.people = []string{contact("c1", "One v2"), contact("c2", "Two v2"), contact("c3", "Three v2")}
	blocker := filepath.Join(dir, ".syncthing.c2.vcf.tmp") // makes the rewrite of c2 fail
	if err := os.Mkdir(blocker, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := runManifest(t, context.Background(), api, dir, mf); err == nil {
		t.Fatal("want a hard error")
	}
	c1 := hash([]byte(read(t, filepath.Join(dir, "c1.vcf"))))
	want := c1 + "  c1.vcf\n" + c2 + "  c2.vcf\n" + c3 + "  c3.vcf\n" + c4 + "  c4.vcf\n"
	if got := read(t, mf); got != want {
		t.Fatalf("manifest after abort:\n%s\nwant (c1 rewritten, the rest carried forward):\n%s", got, want)
	}
	if k := keptIn(t, dir, "c1"); len(k) != 1 || read(t, k[0]) != "EDITED1" {
		t.Errorf("edited c1 not kept: %v", k)
	}
}

// The manifest lists what the run wrote, never what is on disk afterwards: a
// vCard changed on disk during the run is flagged by the next one.
func TestManifestIsNotFromDisk(t *testing.T) {
	fastBackoff(t)
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	ps := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		write(t, filepath.Join(dir, "c1.vcf"), "RACE") // c1 was handled before c2's photo is fetched
		http.NotFound(w, r)
	}))
	defer ps.Close()
	api := &fakeAPI{people: []string{contact("c1", "One"), photoContact("c2", "Two", ps.URL+"/p")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err == nil {
		t.Fatal("want photo error")
	}
	if strings.Contains(read(t, mf), hash([]byte("RACE"))) {
		t.Fatal("manifest blessed a vCard written by someone else")
	}
	api.people = []string{contact("c1", "One"), contact("c2", "Two")}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	if k := keptIn(t, dir, "c1"); len(k) != 1 || read(t, k[0]) != "RACE" {
		t.Errorf("mid-run edit of c1 not kept next run: %v", k)
	}
}

// Cancelling the context (SIGTERM) stops the loop and still writes the manifest.
func TestCancelWritesManifest(t *testing.T) {
	fastBackoff(t)
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three"), contact("c4", "Four")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	before := read(t, mf)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ps := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cancel()
		http.NotFound(w, r)
	}))
	defer ps.Close()
	api.people = []string{contact("c1", "One"), photoContact("c2", "Two", ps.URL+"/p"), contact("c3", "Three v2"), contact("c4", "Four")}
	if err := runManifest(t, ctx, api, dir, mf); err == nil {
		t.Fatal("want cancellation error")
	}
	if h := historyOf(t, mf); !strings.Contains(h[len(h)-1][5], "unchanged=1") {
		t.Errorf("stopped run line %q lacks the totals so far", h[len(h)-1])
	}
	if strings.Contains(read(t, filepath.Join(dir, "c3.vcf")), "Three v2") {
		t.Error("loop went on after cancellation")
	}
	got := strings.Split(strings.TrimSuffix(read(t, mf), "\n"), "\n")
	if len(got) != 4 || strings.Split(got[2], "  ")[0] != strings.Split(strings.Split(before, "\n")[2], "  ")[0] {
		t.Errorf("manifest after cancel:\n%s\nbefore:\n%s", read(t, mf), before)
	}
	if !strings.Contains(read(t, mf), hash([]byte(read(t, filepath.Join(dir, "c2.vcf"))))+"  c2.vcf") {
		t.Error("manifest lacks the vCard written before the cancel")
	}
}

// An edited vCard's photo is not reused: the card comes back as Google has it.
func TestEditedCardPhotoRefetched(t *testing.T) {
	fp := &fakePhotos{bodies: map[string][]byte{"/a": jpeg}}
	ps := httptest.NewServer(fp)
	defer ps.Close()
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/a")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	orig := read(t, filepath.Join(dir, "c1.vcf"))
	var p person
	if err := json.Unmarshal([]byte(api.people[0]), &p); err != nil {
		t.Fatal(err)
	}
	other := append(append([]byte{}, jpeg...), "tampered"...)
	write(t, filepath.Join(dir, "c1.vcf"), string(render(p, nil, &photo{ps.URL + "/a", "JPEG", base64.StdEncoding.EncodeToString(other), ""})))
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(dir, "c1.vcf")); got != orig {
		t.Error("tampered photo survived in the rewritten card")
	}
	if fp.hits.Load() != 2 {
		t.Errorf("want the photo fetched again (2 downloads), got %d", fp.hits.Load())
	}
	if k := keptIn(t, dir, "c1"); len(k) != 1 {
		t.Errorf("edited card not kept: %v", k)
	}
}

// A vCard that vanishes between the listing and the read (here a dangling
// symlink) is skipped, not fatal.
func TestVanishedVCardSkipped(t *testing.T) {
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{contact("c1", "One")}}
	if err := run(t, api, dir); err != nil {
		t.Fatal(err)
	}
	write(t, mf, "")
	if err := os.Symlink(filepath.Join(dir, "nowhere"), filepath.Join(dir, "c9.vcf")); err != nil {
		t.Fatal(err)
	}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatalf("vanished vCard failed the run: %v", err)
	}
}

// An edit that lands while a photo is fetched is kept, not overwritten: both
// for a vCard handled later in the run and for the one whose photo is fetched.
func TestEditDuringRunIsKept(t *testing.T) {
	for name, victim := range map[string]string{"later vCard": "c2", "own vCard": "c1"} {
		dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
		api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two")}}
		if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
			t.Fatal(err)
		}
		ps := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			f, err := os.OpenFile(filepath.Join(dir, victim+".vcf"), os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				t.Error(err)
				return
			}
			f.WriteString("EDIT\r\n")
			f.Close()
			w.Write(jpeg)
		}))
		api.people = []string{photoContact("c1", "One", ps.URL+"/p"), contact("c2", "Two v2")}
		if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		ps.Close()
		if k := keptIn(t, dir, victim); len(k) != 1 || !strings.Contains(read(t, k[0]), "EDIT") {
			t.Errorf("%s: edit during the run not kept: %v", name, k)
		}
	}
}

func TestContactsRequiresManifest(t *testing.T) {
	if err := contactsCmd(context.Background(), []string{"-out", t.TempDir()}); err == nil || !strings.Contains(err.Error(), "-manifest") {
		t.Fatalf("want a -manifest error, got %v", err)
	}
}

// A contact gone from Google is kept as -deleted-<date>, or -deleted-<time>
// when that is taken; an edited one as -kept-. Copies are left alone after.
func TestContactsDeleted(t *testing.T) {
	fixedClock(t)
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	api := &fakeAPI{people: []string{contact("c1", "One"), contact("c2", "Two"), contact("c3", "Three"), contact("c4", "Four"), contact("c5", "Five")}}
	if err := runManifest(t, context.Background(), api, dir, mf); err != nil {
		t.Fatal(err)
	}
	c5 := read(t, filepath.Join(dir, "c5.vcf"))
	write(t, filepath.Join(dir, "c5-deleted-2026-11-23.vcf"), "taken")
	write(t, filepath.Join(dir, "c5-deleted-2026-11-23-001502.vcf"), "taken")
	c2, c4 := read(t, filepath.Join(dir, "c2.vcf")), read(t, filepath.Join(dir, "c4.vcf"))
	write(t, filepath.Join(dir, "c3.vcf"), "EDITED3")
	write(t, filepath.Join(dir, "c4-deleted-2026-11-23.vcf"), "taken")
	api.people = []string{contact("c1", "One")}
	var err error
	logs := captureStderr(t, func() { err = runManifest(t, context.Background(), api, dir, mf) })
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{
		"c2-deleted-2026-11-23.vcf": c2, "c4-deleted-2026-11-23.vcf": "taken",
		"c4-deleted-2026-11-23-001502.vcf": c4, "c3-kept-2026-11-23-001502.vcf": "EDITED3",
		"c5-kept-2026-11-23-001502.vcf": c5,
	} {
		if got := read(t, filepath.Join(dir, name)); got != want {
			t.Errorf("%s: got %q, want %q", name, got, want)
		}
	}
	if got := state(t, dir); len(got) != 8 {
		t.Errorf("want c1 and 7 copies, got %v", got)
	}
	if !strings.Contains(logs, "contacts: 2 deleted in Google, kept as *-deleted-2026-11-23*.vcf\n") || !strings.Contains(logs, "contacts: 2 changed on disk") || strings.Contains(logs, "c2") {
		t.Errorf("logs:\n%s", logs)
	}
	hist := historyOf(t, mf)
	hasHistory(t, hist, "contacts", "deleted", "-", hash([]byte(c2)), `"c2.vcf"`, `"c2-deleted-2026-11-23.vcf"`)
	hasHistory(t, hist, "contacts", "deleted", "-", hash([]byte(c4)), `"c4.vcf"`, `"c4-deleted-2026-11-23-001502.vcf"`)
	hasHistory(t, hist, "contacts", "kept", "-", hash([]byte("EDITED3")), `"c3.vcf"`, `"c3-kept-2026-11-23-001502.vcf"`)
	hasHistory(t, hist, "contacts", "new", `"people/c1"`, hash([]byte(read(t, filepath.Join(dir, "c1.vcf")))), `"c1.vcf"`)
	runTotals(t, hist, "contacts", logs)
	if m := read(t, mf); strings.Count(m, "\n") != 1 || !strings.Contains(m, "c1.vcf") {
		t.Errorf("manifest:\n%s", m)
	}
	before := state(t, dir)
	logs = captureStderr(t, func() { err = runManifest(t, context.Background(), api, dir, mf) })
	if err != nil || !maps.Equal(state(t, dir), before) || strings.Contains(logs, "deleted in Google") || !strings.Contains(logs, " 1 vCards in") {
		t.Errorf("copies touched or counted: %v\n%s", err, logs)
	}
}

// fixedClock makes each run of the test start a second after the last, from
// 2026-11-23 00:15:00 local.
func fixedClock(t *testing.T) {
	old := now
	t.Cleanup(func() { now = old })
	clock := time.Date(2026, 11, 23, 0, 15, 0, 0, time.Local)
	now = func() time.Time { clock = clock.Add(time.Second); return clock }
}

// A vCard edited before the run and again during its photo fetch is kept
// twice.
func TestContactsEditedTwice(t *testing.T) {
	fixedClock(t)
	dir, mf := t.TempDir(), filepath.Join(t.TempDir(), "manifest")
	if err := runManifest(t, context.Background(), &fakeAPI{people: []string{contact("c1", "One")}}, dir, mf); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(dir, "c1.vcf"), "EDIT BEFORE")
	ps := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		os.WriteFile(filepath.Join(dir, "c1.vcf"), []byte("EDIT DURING"), 0o600)
		w.Write(jpeg)
	}))
	defer ps.Close()
	if err := runManifest(t, context.Background(), &fakeAPI{people: []string{photoContact("c1", "One", ps.URL+"/p")}}, dir, mf); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, k := range keptIn(t, dir, "c1") {
		got = append(got, read(t, k))
	}
	if slices.Sort(got); !slices.Equal(got, []string{"EDIT BEFORE", "EDIT DURING"}) {
		t.Errorf("kept copies %q", got)
	}
}

// A run out of time failed; only a signal stops one.
func TestDeadlineIsFailure(t *testing.T) {
	ctx, cancel := context.WithDeadline(context.Background(), time.Unix(0, 0))
	defer cancel()
	if err := runManifest(t, ctx, &fakeAPI{}, t.TempDir(), filepath.Join(t.TempDir(), "manifest")); err == nil {
		t.Error("run out of time succeeded")
	}
}
