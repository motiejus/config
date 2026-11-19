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

func run(t *testing.T, api *fakeAPI, dir string) error {
	t.Helper()
	srv := httptest.NewServer(api)
	defer srv.Close()
	peopleAPI = srv.URL
	return syncDir(context.Background(), srv.Client(), dir)
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
	if _, ok := got["c3.vcf"]; ok {
		t.Error("deleted contact c3 still on disk")
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
	if len(got) != 4 {
		t.Errorf("want exactly 4 files (no temp files left), got %v", got)
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
	if err := syncDir(context.Background(), srv.Client(), t.TempDir()); err == nil || !strings.Contains(err.Error(), "nope") {
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
	return syncDir(context.Background(), &http.Client{Transport: bearer{srv.Client().Transport}}, dir)
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
		api := &fakeAPI{people: []string{photoContact("c1", "One renamed", ps.URL+bad), photoContact("c3", "Three", ps.URL+"/ok")}}
		err := runAuth(t, api, dir)
		if err == nil || !strings.Contains(err.Error(), "people/c1") || strings.Contains(err.Error(), ps.URL) {
			t.Fatalf("%s: want an error naming c1 but not the URL, got %v", bad, err)
		}
		card := read(t, filepath.Join(dir, "c1.vcf"))
		if ph, _, src := decodePhotos(t, card); len(ph) != 1 || !bytes.Equal(ph[0], jpeg) || src[0] != ps.URL+"/ok" {
			t.Errorf("%s: old photo and source must survive a failed fetch", bad)
		}
		if !strings.Contains(card, "FN:One renamed") || !strings.Contains(read(t, filepath.Join(dir, "c3.vcf")), "FN:Three") {
			t.Errorf("%s: field change or other contact not written", bad)
		}
		os.Remove(filepath.Join(dir, "c3.vcf"))
		os.WriteFile(filepath.Join(dir, "c1.vcf"), []byte(strings.Replace(card, "One renamed", "One", 1)), 0o600)
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
	if !strings.Contains(logged, "people/c1") || strings.Contains(logged, ps.URL) {
		t.Errorf("night 2 log: want people/c1 and no URL, got %q", logged)
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
