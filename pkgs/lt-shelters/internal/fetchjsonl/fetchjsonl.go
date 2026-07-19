package fetchjsonl

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const userAgent = "lt-shelters-fetcher/1.0 (+https://git.jakstys.lt/lt-shelters)"

const (
	maxResponseBytes = 32 << 20
	maxRecordBytes   = 1 << 20
)

// splitLinesKeepEnd is bufio.ScanLines with the line ending retained so a
// validated download can be committed byte-for-byte as published.
func splitLinesKeepEnd(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		return i + 1, data[:i+1], nil
	}
	if atEOF && len(data) != 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

// Fetch downloads a JSON Lines dataset, validates every record, and atomically
// replaces output. The response bytes themselves are not re-encoded.
func Fetch(client *http.Client, url, datasetType string, minimumRecords int, output string) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/x-ndjson, application/json")
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return fmt.Errorf("download %s: HTTP %s", url, resp.Status)
	}

	dir := filepath.Dir(output)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(output)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary output: %w", err)
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		_ = tmp.Close()
		if !ok {
			_ = os.Remove(tmpName)
		}
	}()

	limited := &io.LimitedReader{R: resp.Body, N: maxResponseBytes + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 64<<10), maxRecordBytes)
	scanner.Split(splitLinesKeepEnd)
	records := 0
	ids := make(map[string]struct{})
	for scanner.Scan() {
		line := scanner.Bytes()
		lineNumber := records + 1
		trimmed := bytes.TrimSpace(line)
		if len(trimmed) == 0 {
			return fmt.Errorf("record %d is empty", lineNumber)
		}
		var envelope struct {
			Type string `json:"_type"`
			ID   string `json:"_id"`
		}
		if err := json.Unmarshal(trimmed, &envelope); err != nil {
			return fmt.Errorf("record %d is not valid JSON: %w", lineNumber, err)
		}
		if envelope.Type != datasetType || envelope.ID == "" {
			return fmt.Errorf("record %d is not a %q dataset record", lineNumber, datasetType)
		}
		if _, exists := ids[envelope.ID]; exists {
			return fmt.Errorf("record %d repeats _id %q", lineNumber, envelope.ID)
		}
		ids[envelope.ID] = struct{}{}
		if _, err := tmp.Write(line); err != nil {
			return fmt.Errorf("write temporary output: %w", err)
		}
		records++
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if limited.N == 0 {
		return fmt.Errorf("dataset exceeds %d bytes", maxResponseBytes)
	}
	if records < minimumRecords {
		return fmt.Errorf("dataset contains %d records, fewer than safety minimum %d", records, minimumRecords)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync temporary output: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temporary output: %w", err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return fmt.Errorf("set output permissions: %w", err)
	}
	if err := os.Rename(tmpName, output); err != nil {
		return fmt.Errorf("replace output: %w", err)
	}
	ok = true
	return nil
}

// Main implements the deliberately small command-line interface shared by the
// two fixed-source downloaders.
func Main(client *http.Client, url, datasetType string, minimumRecords int, args []string, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(stderr, "usage: "+filepath.Base(args[0])+" OUTPUT.jsonl")
		return 2
	}
	if err := Fetch(client, url, datasetType, minimumRecords, args[1]); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
