// Command google-contacts mirrors Google contacts into a directory of vCards.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const scope = "https://www.googleapis.com/auth/contacts.readonly"

var peopleAPI = "https://people.googleapis.com/v1"

func main() {
	var err error
	switch {
	case len(os.Args) > 1 && os.Args[1] == "auth":
		err = authCmd(os.Args[2:])
	case len(os.Args) > 1 && os.Args[1] == "sync":
		err = syncCmd(os.Args[2:])
	default:
		fmt.Fprintln(os.Stderr, "usage:\n  google-contacts auth -client FILE -out FILE\n  google-contacts sync [-token FILE] -out DIR")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "google-contacts:", err)
		os.Exit(1)
	}
}

func syncCmd(args []string) error {
	fs := flag.NewFlagSet("sync", flag.ExitOnError)
	tokenFile := fs.String("token", "", "authorized_user JSON (default: $GOOGLE_CONTACTS_TOKEN)")
	out := fs.String("out", "", "output directory")
	fs.Parse(args)
	if *out == "" {
		return errors.New("sync: -out is required")
	}
	data := []byte(os.Getenv("GOOGLE_CONTACTS_TOKEN"))
	if *tokenFile != "" {
		var err error
		if data, err = os.ReadFile(*tokenFile); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	creds, err := google.CredentialsFromJSONWithType(ctx, data, google.AuthorizedUser, scope)
	if err != nil {
		return fmt.Errorf("token: %w", err)
	}
	return syncDir(ctx, oauth2.NewClient(ctx, creds.TokenSource), *out)
}

// syncDir writes one vCard per contact into dir, rewriting only files whose
// bytes changed and removing vCards of contacts that are gone. A contact whose
// photo cannot be fetched keeps its file; the error is returned at the end.
func syncDir(ctx context.Context, c *http.Client, dir string) error {
	people, err := listPeople(ctx, c)
	if err != nil {
		return err
	}
	groups, err := listGroups(ctx, c)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	old, err := filepath.Glob(filepath.Join(dir, "*.vcf"))
	if err != nil {
		return err
	}
	if len(people) == 0 && len(old) > 0 {
		return fmt.Errorf("Google returned no contacts; keeping the %d in %s", len(old), dir)
	}
	keep := map[string]bool{}
	var failed []error
	for _, p := range people {
		name := fileName(p.ResourceName)
		path := filepath.Join(dir, name)
		keep[path] = true
		cur, _ := os.ReadFile(path)
		ph, err := photoFor(ctx, p, cur)
		if err != nil {
			failed = append(failed, fmt.Errorf("%s: %w", p.ResourceName, err))
		}
		card := render(p, groups, ph)
		if bytes.Equal(cur, card) {
			continue
		}
		// Syncthing does not scan .syncthing.* names.
		tmp := filepath.Join(dir, ".syncthing."+name+".tmp")
		if err := os.WriteFile(tmp, card, 0o600); err != nil {
			return err
		}
		if err := os.Rename(tmp, path); err != nil {
			return err
		}
	}
	for _, path := range old {
		if !keep[path] {
			if err := os.Remove(path); err != nil {
				return err
			}
		}
	}
	return errors.Join(failed...)
}

var unsafeChars = regexp.MustCompile(`[^A-Za-z0-9_-]`)

func fileName(resourceName string) string {
	return unsafeChars.ReplaceAllString(strings.TrimPrefix(resourceName, "people/"), "_") + ".vcf"
}

type value struct {
	Value    string
	Type     string
	Metadata struct {
		Primary bool
	}
}

type date struct {
	Year, Month, Day int
}

type nameEntry struct {
	DisplayName, FamilyName, GivenName, MiddleName, HonorificPrefix, HonorificSuffix string
	Metadata                                                                         struct{ Primary bool }
}

type person struct {
	ResourceName   string
	Names          []nameEntry
	Nicknames      []value
	EmailAddresses []value
	PhoneNumbers   []value
	Urls           []value
	Biographies    []value
	Addresses      []struct {
		value
		PoBox, StreetAddress, ExtendedAddress, City, Region, PostalCode, Country string
	}
	Organizations []struct{ Name, Department, Title string }
	Birthdays     []struct {
		Date *date
		Text string
	}
	Events []struct {
		value
		Date date
	}
	Relations []struct {
		value
		Person string
	}
	ImClients []struct {
		value
		Username, Protocol string
	}
	Photos []struct {
		URL     string
		Default bool
	}
	UserDefined []struct{ Key, Value string }
	Memberships []struct {
		ContactGroupMembership struct {
			ContactGroupResourceName string
		}
	}
}

const personFields = "addresses,biographies,birthdays,emailAddresses,events,imClients,memberships," +
	"metadata,names,nicknames,organizations,phoneNumbers,photos,relations,urls,userDefined"

func listPeople(ctx context.Context, c *http.Client) ([]person, error) {
	var all []person
	q := url.Values{"personFields": {personFields}, "pageSize": {"1000"}}
	for {
		var page struct {
			Connections   []person
			NextPageToken string
		}
		if err := get(ctx, c, "/people/me/connections", q, &page); err != nil {
			return nil, err
		}
		all = append(all, page.Connections...)
		if page.NextPageToken == "" {
			return all, nil
		}
		q.Set("pageToken", page.NextPageToken)
	}
}

// listGroups maps user-created contact group resource names to their names.
func listGroups(ctx context.Context, c *http.Client) (map[string]string, error) {
	groups := map[string]string{}
	q := url.Values{"pageSize": {"1000"}}
	for {
		var page struct {
			ContactGroups []struct{ ResourceName, FormattedName, GroupType string }
			NextPageToken string
		}
		if err := get(ctx, c, "/contactGroups", q, &page); err != nil {
			return nil, err
		}
		for _, g := range page.ContactGroups {
			if g.GroupType == "USER_CONTACT_GROUP" {
				groups[g.ResourceName] = g.FormattedName
			}
		}
		if page.NextPageToken == "" {
			return groups, nil
		}
		q.Set("pageToken", page.NextPageToken)
	}
}

// photo is the embedded picture of a contact; B64 is its base64 form.
// Failed is the URL whose last fetch failed (X-PHOTO-FAILED); with no B64 the
// card has no picture.
type photo struct{ Source, Type, B64, Failed string }

const (
	photoSize     = "720" // People API: append sz={size} (pixels) to Photo.url.
	maxPhotoBytes = 10 << 20
)

// photoClient is deliberately not the OAuth client: lh3.googleusercontent.com
// photo URLs carry their own unguessable token and need no bearer token.
var photoClient = &http.Client{Timeout: 20 * time.Second}

// sizeSuffix is the "=s100"-style size option ending a current photo URL.
var sizeSuffix = regexp.MustCompile(`=s\d+[^/]*$`)

// sizedURL asks for photoSize pixels: it rewrites a trailing "=s<N>" option, which
// makes sz= a no-op, else appends sz= to the older /s100/photo.jpg shape.
func sizedURL(src string) (string, error) {
	u, err := url.Parse(src)
	if err != nil {
		return "", errors.New("invalid photo URL")
	}
	if ep := u.EscapedPath(); sizeSuffix.MatchString(ep) {
		ep = sizeSuffix.ReplaceAllString(ep, "=s"+photoSize)
		if u.Path, err = url.PathUnescape(ep); err != nil {
			return "", errors.New("invalid photo URL")
		}
		u.RawPath = ep
	} else {
		q := u.Query()
		q.Set("sz", photoSize)
		u.RawQuery = q.Encode()
	}
	return u.String(), nil
}

// photoFor returns the first non-default photo of p, taken from the existing
// vCard cur when its X-PHOTO-SOURCE is unchanged and downloaded otherwise. On
// failure it returns cur's old photo, if any, marked Failed with the URL so the
// rest of the contact is still written. The error is returned only when cur
// did not already mark that URL failed; a repeat is logged instead.
func photoFor(ctx context.Context, p person, cur []byte) (*photo, error) {
	var src string
	for _, ph := range p.Photos {
		if !ph.Default && ph.URL != "" {
			src = ph.URL
			break
		}
	}
	if src == "" {
		return nil, nil
	}
	kept := parsePhoto(cur)
	if kept.Source == src {
		kept.Failed = ""
		return &kept, nil
	}
	ph, err := fetchPhoto(ctx, src)
	if err == nil {
		return ph, nil
	}
	repeat := kept.Failed == src
	kept.Failed = src
	if repeat { // Already counted on the first night: log, do not fail the run.
		fmt.Fprintf(os.Stderr, "%s: %v (known failure)\n", p.ResourceName, err)
		return &kept, nil
	}
	return &kept, err
}

func fetchPhoto(ctx context.Context, src string) (*photo, error) {
	u, err := sizedURL(src)
	if err != nil {
		return nil, err
	}
	var data []byte
	err = withRetry(ctx, func() (time.Duration, error) {
		var retry time.Duration
		data, retry, err = photoOnce(ctx, u)
		return retry, err
	})
	if err != nil {
		return nil, fmt.Errorf("photo: %w", err)
	}
	typ, err := photoType(data)
	if err != nil {
		return nil, fmt.Errorf("photo: %w", err)
	}
	return &photo{src, typ, base64.StdEncoding.EncodeToString(data), ""}, nil
}

// photoType names the image format of data, or fails if it is not JPEG, PNG or GIF.
func photoType(data []byte) (string, error) {
	switch ct := http.DetectContentType(data); ct {
	case "image/jpeg", "image/png", "image/gif":
		return strings.ToUpper(strings.TrimPrefix(ct, "image/")), nil
	default:
		return "", fmt.Errorf("unsupported content type %s", ct)
	}
}

// unfold undoes content-line folding: CRLF plus one space or tab.
var unfold = strings.NewReplacer("\r\n ", "", "\r\n\t", "").Replace

// parsePhoto extracts the embedded photo and failed-URL marker of a rendered
// vCard. The photo part is kept only if its data decodes to an image of the
// declared type; the zero photo means neither is present.
func parsePhoto(card []byte) (ph photo) {
	for _, l := range strings.Split(unfold(string(card)), "\r\n") {
		if v, ok := strings.CutPrefix(l, "X-PHOTO-SOURCE:"); ok {
			ph.Source = v
		} else if v, ok := strings.CutPrefix(l, "X-PHOTO-FAILED:"); ok {
			ph.Failed = v
		} else if v, ok := strings.CutPrefix(l, "PHOTO;ENCODING=b;TYPE="); ok {
			ph.Type, ph.B64, _ = strings.Cut(v, ":")
		}
	}
	data, err := base64.StdEncoding.Strict().DecodeString(ph.B64)
	if typ, terr := photoType(data); err != nil || ph.Source == "" || terr != nil || typ != ph.Type {
		ph = photo{Failed: ph.Failed}
	}
	return ph
}

// photoOnce downloads one photo, at most maxPhotoBytes.
func photoOnce(ctx context.Context, u string) (data []byte, retry time.Duration, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, -1, err
	}
	resp, err := photoClient.Do(req)
	if err != nil {
		// The URL is a bearer-like token; keep it out of the error.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, statusRetry(resp), fmt.Errorf("GET photo: %s", resp.Status)
	}
	data, err = io.ReadAll(io.LimitReader(resp.Body, maxPhotoBytes+1))
	if err != nil {
		return nil, 0, err
	}
	if len(data) > maxPhotoBytes {
		return nil, -1, fmt.Errorf("photo larger than %d bytes", maxPhotoBytes)
	}
	return data, -1, nil
}

// backoff holds the waits between the attempts of withRetry.
var backoff = []time.Duration{2 * time.Second, 8 * time.Second}

// get decodes the JSON at path into v, retrying transport errors, 429 and 5xx.
func get(ctx context.Context, c *http.Client, path string, q url.Values, v any) error {
	return withRetry(ctx, func() (time.Duration, error) { return getOnce(ctx, c, path, q, v) })
}

// withRetry runs once until it succeeds or reports a final error, waiting
// per backoff between the attempts; a cancelled ctx ends the waiting, so
// transport errors need no ctx check of their own. once returns what getOnce
// documents.
func withRetry(ctx context.Context, once func() (time.Duration, error)) error {
	for attempt := 0; ; attempt++ {
		retry, err := once()
		if err == nil || retry < 0 || attempt == len(backoff) {
			return err
		}
		if retry == 0 {
			retry = backoff[attempt]
		}
		select {
		case <-time.After(retry):
		case <-ctx.Done():
			return err
		}
	}
}

// getOnce makes one request. A negative retry means the error is final; zero
// means retry after the default backoff, positive is the server's Retry-After.
func getOnce(ctx context.Context, c *http.Client, path string, q url.Values, v any) (retry time.Duration, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, peopleAPI+path+"?"+q.Encode(), nil)
	if err != nil {
		return -1, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var e struct{ Error struct{ Message string } }
		json.NewDecoder(resp.Body).Decode(&e)
		err := fmt.Errorf("GET %s: %s: %s", path, resp.Status, e.Error.Message)
		return statusRetry(resp), err
	}
	return -1, json.NewDecoder(resp.Body).Decode(v)
}

// statusRetry classifies a non-200 response: negative is final, zero retries
// after the default backoff, positive is the server's Retry-After.
func statusRetry(resp *http.Response) time.Duration {
	if resp.StatusCode != http.StatusTooManyRequests && resp.StatusCode < 500 {
		return -1
	}
	if secs, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && secs > 0 {
		return min(time.Duration(secs)*time.Second, time.Minute)
	}
	return 0
}

// render formats p as a vCard 3.0, the version Google Contacts, Apple
// Contacts and Android all import. Properties come out in a fixed order, so
// the bytes change only when the contact does. ph, if not nil, is embedded.
func render(p person, groups map[string]string, ph *photo) []byte {
	var lines []string
	emit := func(name string, params []string, v string) {
		if strings.Trim(v, ";") == "" {
			return
		}
		lines = append(lines, strings.Join(append([]string{name}, params...), ";")+":"+v)
	}
	add := func(name string, params []string, components ...string) {
		for i, c := range components {
			components[i] = escape(dropControls(c))
		}
		emit(name, params, strings.Join(components, ";"))
	}
	// addURI is for URI values, which are not text-escaped.
	addURI := func(name string, params []string, v string) {
		emit(name, params, strings.Map(func(r rune) rune {
			if r < ' ' || r == 0x7f {
				return -1
			}
			return r
		}, v))
	}
	typ := func(v value, pref bool) []string {
		var ps []string
		if t := paramValue(v.Type); t != "" {
			ps = append(ps, "TYPE="+t)
		}
		if pref && v.Metadata.Primary {
			ps = append(ps, "TYPE=pref")
		}
		return ps
	}

	// One N and one FN: the primary name, else the first.
	var name nameEntry
	if len(p.Names) > 0 {
		name = p.Names[0]
		for _, n := range p.Names {
			if n.Metadata.Primary {
				name = n
				break
			}
		}
	}
	fn := name.DisplayName
	for _, o := range p.Organizations {
		if fn == "" {
			fn = o.Name
		}
		add("ORG", nil, o.Name, o.Department)
		add("TITLE", nil, o.Title)
	}
	for _, e := range p.EmailAddresses {
		if fn == "" {
			fn = e.Value
		}
		add("EMAIL", append([]string{"TYPE=INTERNET"}, typ(e, true)...), e.Value)
	}
	if fn == "" {
		fn = p.ResourceName
	}
	if name.FamilyName+name.GivenName+name.MiddleName+name.HonorificPrefix+name.HonorificSuffix == "" {
		name.FamilyName = fn
	}
	add("N", nil, name.FamilyName, name.GivenName, name.MiddleName, name.HonorificPrefix, name.HonorificSuffix)
	add("FN", nil, fn)
	add("UID", nil, p.ResourceName)
	for _, v := range p.Nicknames {
		add("NICKNAME", nil, v.Value)
	}
	for _, v := range p.PhoneNumbers {
		add("TEL", typ(v, true), v.Value)
	}
	for _, a := range p.Addresses {
		add("ADR", typ(a.value, true), a.PoBox, a.ExtendedAddress, a.StreetAddress, a.City, a.Region, a.PostalCode, a.Country)
	}
	for _, b := range p.Birthdays {
		if b.Date != nil {
			add("BDAY", nil, formatDate(*b.Date))
		} else if b.Text != "" {
			add("BDAY", []string{"VALUE=text"}, b.Text)
		}
	}
	for _, e := range p.Events {
		if e.Type == "anniversary" {
			add("X-ANNIVERSARY", nil, formatDate(e.Date))
		} else {
			add("X-EVENT", typ(e.value, false), formatDate(e.Date))
		}
	}
	for _, v := range p.Urls {
		addURI("URL", typ(v, false), v.Value)
	}
	for _, v := range p.Biographies {
		add("NOTE", nil, v.Value)
	}
	for _, im := range p.ImClients {
		params := typ(im.value, false)
		if proto := paramValue(im.Protocol); proto != "" {
			params = append(params, "X-SERVICE-TYPE="+proto)
		}
		add("IMPP", params, im.Username)
	}
	for _, r := range p.Relations {
		add("X-RELATION", typ(r.value, false), r.Person)
	}
	if ph != nil {
		if ph.B64 != "" {
			emit("PHOTO", []string{"ENCODING=b", "TYPE=" + ph.Type}, ph.B64)
			addURI("X-PHOTO-SOURCE", nil, ph.Source)
		}
		addURI("X-PHOTO-FAILED", nil, ph.Failed) // no-op when empty
	}
	for _, u := range p.UserDefined {
		add("X-USER-DEFINED", nil, u.Key+": "+u.Value)
	}
	var cats []string
	for _, m := range p.Memberships {
		if g, ok := groups[m.ContactGroupMembership.ContactGroupResourceName]; ok {
			cats = append(cats, escape(g))
		}
	}
	slices.Sort(cats)
	if len(cats) > 0 {
		lines = append(lines, "CATEGORIES:"+strings.Join(cats, ","))
	}

	var b bytes.Buffer
	b.WriteString("BEGIN:VCARD\r\nVERSION:3.0\r\n")
	for _, l := range lines {
		b.WriteString(fold(l))
	}
	b.WriteString("END:VCARD\r\n")
	return b.Bytes()
}

// escape renders s as a vCard text value; a bare \r is a line break.
var escape = strings.NewReplacer(`\`, `\\`, "\r\n", `\n`, "\n", `\n`, "\r", `\n`, ",", `\,`, ";", `\;`).Replace

// dropControls removes C0 controls and DEL, keeping the line breaks and tab
// that text values can carry.
func dropControls(s string) string {
	return strings.Map(func(r rune) rune {
		if (r < ' ' && r != '\t' && r != '\n' && r != '\r') || r == 0x7f {
			return -1
		}
		return r
	}, s)
}

// paramValue keeps a TYPE value to characters that need no quoting.
func paramValue(s string) string {
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(`";:,`, r) || r < ' ' {
			return -1
		}
		return r
	}, s)
}

// formatDate returns "" for a year-only date, which vCard 3.0 cannot express.
func formatDate(d date) string {
	if d.Month == 0 || d.Day == 0 {
		return ""
	}
	if d.Year == 0 {
		return fmt.Sprintf("--%02d%02d", d.Month, d.Day)
	}
	return fmt.Sprintf("%04d-%02d-%02d", d.Year, d.Month, d.Day)
}

// fold splits a content line into 75-octet chunks without breaking UTF-8.
func fold(line string) string {
	var b strings.Builder
	b.Grow(len(line) + len(line)/74*3 + 2)
	for limit := 75; len(line) > limit; limit = 74 {
		cut := limit
		for cut > 0 && line[cut]&0xC0 == 0x80 {
			cut--
		}
		b.WriteString(line[:cut] + "\r\n ")
		line = line[cut:]
	}
	b.WriteString(line + "\r\n")
	return b.String()
}

func authCmd(args []string) (err error) {
	fs := flag.NewFlagSet("auth", flag.ExitOnError)
	client := fs.String("client", "", "OAuth Desktop client JSON from the Google Cloud console")
	out := fs.String("out", "", "where to write the authorized_user JSON")
	fs.Parse(args)
	if *client == "" || *out == "" {
		return errors.New("auth: -client and -out are required")
	}
	data, err := os.ReadFile(*client)
	if err != nil {
		return err
	}
	cfg, err := google.ConfigFromJSON(data, scope)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(*out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			os.Remove(*out)
		}
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer ln.Close()
	cfg.RedirectURL = fmt.Sprintf("http://%s/", ln.Addr())
	state, verifier := rand.Text(), oauth2.GenerateVerifier()
	fmt.Fprintf(os.Stderr, "Open this URL in a browser and approve access:\n\n%s\n\n",
		cfg.AuthCodeURL(state, oauth2.AccessTypeOffline, oauth2.ApprovalForce, oauth2.S256ChallengeOption(verifier)))

	results := make(chan authResult, 1)
	go http.Serve(ln, callback(state, results))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	var code string
	select {
	case res := <-results:
		if res.err != nil {
			return res.err
		}
		code = res.code
	case <-ctx.Done():
		return errors.New("timed out waiting for authorization")
	}
	tok, err := cfg.Exchange(ctx, code, oauth2.VerifierOption(verifier))
	if err != nil {
		return err
	}
	if tok.RefreshToken == "" {
		return errors.New("no refresh token returned")
	}
	return json.NewEncoder(f).Encode(map[string]string{
		"type":          "authorized_user",
		"client_id":     cfg.ClientID,
		"client_secret": cfg.ClientSecret,
		"refresh_token": tok.RefreshToken,
	})
}

type authResult struct {
	code string
	err  error
}

// callback handles the loopback redirect: the first request carrying the
// right state yields the code, or the error if the user denied consent.
func callback(state string, results chan<- authResult) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("state") != state || (q.Get("code") == "" && q.Get("error") == "") {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		res := authResult{code: q.Get("code")}
		if e := q.Get("error"); e != "" {
			res.err = fmt.Errorf("authorization failed: %s", e)
			http.Error(w, res.err.Error(), http.StatusForbidden)
		} else {
			fmt.Fprintln(w, "Authorized. You can close this tab.")
		}
		select {
		case results <- res:
		default:
		}
	})
}
