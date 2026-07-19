package main

import (
	"net/http"
	"os"
	"time"

	"git.jakstys.lt/motiejus/config/pkgs/lt-shelters/internal/fetchjsonl"
)

const (
	url         = "https://get.data.gov.lt/datasets/gov/pagd/priedangos/Priedanga/:format/jsonl"
	datasetType = "datasets/gov/pagd/priedangos/Priedanga"
)

func main() {
	client := &http.Client{Timeout: 5 * time.Minute}
	os.Exit(fetchjsonl.Main(client, url, datasetType, 5000, os.Args, os.Stderr))
}
