package fetchjsonl

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testType = "datasets/gov/pagd/test/Record"

func TestFetchPreservesSourceBytes(t *testing.T) {
	body := "{\"_type\":\"" + testType + "\",\"_id\":\"one\",\"x\":\"ą\"}\r\n" +
		"{\"_type\":\"" + testType + "\",\"_id\":\"two\",\"x\":2}"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("User-Agent"); got != userAgent {
			t.Errorf("User-Agent = %q", got)
		}
		_, _ = w.Write([]byte(body))
	}))
	defer server.Close()

	output := filepath.Join(t.TempDir(), "nested", "data.jsonl")
	if err := Fetch(server.Client(), server.URL, testType, 2, output); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body {
		t.Fatalf("output bytes changed:\n got %q\nwant %q", got, body)
	}
}

func TestFetchDoesNotReplaceGoodFileOnBadResponses(t *testing.T) {
	tests := map[string]struct {
		status int
		body   string
	}{
		"http error":     {status: http.StatusServiceUnavailable, body: "later"},
		"empty":          {status: http.StatusOK},
		"malformed":      {status: http.StatusOK, body: "{broken}\n"},
		"wrong dataset":  {status: http.StatusOK, body: "{\"_type\":\"other\",\"_id\":\"one\"}\n"},
		"missing id":     {status: http.StatusOK, body: "{\"_type\":\"" + testType + "\"}\n"},
		"duplicate id":   {status: http.StatusOK, body: "{\"_type\":\"" + testType + "\",\"_id\":\"one\"}\n{\"_type\":\"" + testType + "\",\"_id\":\"one\"}\n"},
		"partial":        {status: http.StatusOK, body: "{\"_type\":\"" + testType + "\",\"_id\":\"one\"}\n"},
		"oversized line": {status: http.StatusOK, body: strings.Repeat(" ", maxRecordBytes+1)},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			output := filepath.Join(t.TempDir(), "data.jsonl")
			if err := os.WriteFile(output, []byte("known good\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			minimumRecords := 1
			if name == "partial" {
				minimumRecords = 2
			}
			if err := Fetch(server.Client(), server.URL, testType, minimumRecords, output); err == nil {
				t.Fatal("Fetch unexpectedly succeeded")
			}
			got, err := os.ReadFile(output)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != "known good\n" {
				t.Fatalf("old output replaced with %q", got)
			}
		})
	}
}

func TestMainUsage(t *testing.T) {
	var stderr strings.Builder
	if got := Main(http.DefaultClient, "unused", testType, 1, []string{"fetch-test"}, &stderr); got != 2 {
		t.Fatalf("exit code = %d, want 2", got)
	}
	if !strings.Contains(stderr.String(), "OUTPUT.jsonl") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestMainDownloadsToArgument(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("{\"_type\":\"" + testType + "\",\"_id\":\"one\"}\n"))
	}))
	defer server.Close()
	output := filepath.Join(t.TempDir(), "output.jsonl")
	var stderr strings.Builder
	if got := Main(server.Client(), server.URL, testType, 1, []string{"fetch-test", output}, &stderr); got != 0 {
		t.Fatalf("exit code = %d, stderr = %q", got, stderr.String())
	}
	if _, err := os.Stat(output); err != nil {
		t.Fatal(err)
	}
}
