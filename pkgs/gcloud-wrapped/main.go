package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	cachePath      = ".config/gcloud/config-helper-cache.json"
	cacheThreshold = 1 * time.Second
)

type credentialCache struct {
	Credential struct {
		TokenExpiry string `json:"token_expiry"`
	} `json:"credential"`
}

func getCachePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, cachePath), nil
}

func argsMatch(args []string) bool {
	return len(args) == 4 &&
		args[0] == "config" &&
		args[1] == "config-helper" &&
		args[2] == "--format" &&
		args[3] == "json"
}

func parseISO8601(s string) (time.Time, error) {
	return time.Parse(time.RFC3339, s)
}

func execGcloud(args []string) {
	argv := make([]string, len(args))
	argv[0] = "gcloud-wrapped"
	copy(argv[1:], args[1:])

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
	os.Exit(0)
}

func runGcloudAndCache(cachePath string) error {
	cmd := exec.Command("gcloud-wrapped", "config", "config-helper", "--format", "json")
	output, err := cmd.CombinedOutput()

	if err != nil {
		os.Remove(cachePath)
		os.Stderr.Write(output)
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}

	if err := os.MkdirAll(filepath.Dir(cachePath), 0755); err != nil {
		return err
	}

	if err := os.WriteFile(cachePath, output, 0600); err != nil {
		return err
	}

	os.Stdout.Write(output)
	return nil
}

func main() {
	args := os.Args[1:]

	if !argsMatch(args) {
		execGcloud(os.Args)
	}

	cachePath, err := getCachePath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get cache path: %v\n", err)
		os.Exit(1)
	}

	cacheData, err := os.ReadFile(cachePath)
	if err != nil {
		if os.IsNotExist(err) {
			if err := runGcloudAndCache(cachePath); err != nil {
				fmt.Fprintf(os.Stderr, "failed to run gcloud: %v\n", err)
				os.Exit(1)
			}
			return
		}
		fmt.Fprintf(os.Stderr, "failed to read cache: %v\n", err)
		os.Exit(1)
	}

	var cache credentialCache
	if err := json.Unmarshal(cacheData, &cache); err != nil {
		if err := runGcloudAndCache(cachePath); err != nil {
			fmt.Fprintf(os.Stderr, "failed to run gcloud: %v\n", err)
			os.Exit(1)
		}
		return
	}

	expiry, err := parseISO8601(cache.Credential.TokenExpiry)
	if err != nil {
		if err := runGcloudAndCache(cachePath); err != nil {
			fmt.Fprintf(os.Stderr, "failed to run gcloud: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if time.Until(expiry) > cacheThreshold {
		os.Stdout.Write(cacheData)
	} else {
		if err := runGcloudAndCache(cachePath); err != nil {
			fmt.Fprintf(os.Stderr, "failed to run gcloud: %v\n", err)
			os.Exit(1)
		}
	}
}
