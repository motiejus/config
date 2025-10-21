package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"text/template"
	"time"
)

const (
	_urlTemplate  = "https://api.meteo.lt/v1/stations/%s/observations/%s"
	_station      = "vilniaus-ams"
	_promTemplate = `# HELP weather_station_air_temperature_celsius Air temperature in degrees Celsius
# TYPE weather_station_air_temperature_celsius gauge
weather_station_air_temperature_celsius{station="{{ .Station }}"} {{ .AirTemperature }} {{ .TS }}
# HELP weather_station_air_feels_like_celsius Apparent temperature in degrees Celsius
# TYPE weather_station_air_feels_like_celsius gauge
weather_station_air_feels_like_celsius{station="{{ .Station }}"} {{ .FeelsLikeTemperature }} {{ .TS }}
# HELP weather_station_wind_speed_ms Wind speed in meters per second
# TYPE weather_station_wind_speed_ms gauge
weather_station_wind_speed_ms{station="{{ .Station }}"} {{ .WindSpeed }} {{ .TS }}
# HELP weather_station_wind_gust_ms Wind gust speed in meters per second
# TYPE weather_station_wind_gust_ms gauge
weather_station_wind_gust_ms{station="{{ .Station }}"} {{ .WindGust }} {{ .TS }}
# HELP weather_station_wind_direction_degrees Wind direction in degrees
# TYPE weather_station_wind_direction_degrees gauge
weather_station_wind_direction_degrees{station="{{ .Station }}"} {{ .WindDirection }} {{ .TS }}{{ if .CloudCover }}
# HELP weather_station_cloud_cover_percent Cloud cover percentage
# TYPE weather_station_cloud_cover_percent gauge
weather_station_cloud_cover_percent{station="{{ .Station }}"} {{ .CloudCover }} {{ .TS }}{{ end }}
# HELP weather_station_sea_level_pressure_hpa Sea level pressure in hectopascals
# TYPE weather_station_sea_level_pressure_hpa gauge
weather_station_sea_level_pressure_hpa{station="{{ .Station }}"} {{ .SeaLevelPressure }} {{ .TS }}
# HELP weather_station_relative_humidity_percent Relative humidity percentage
# TYPE weather_station_relative_humidity_percent gauge
weather_station_relative_humidity_percent{station="{{ .Station }}"} {{ .RelativeHumidity }} {{ .TS }}
# HELP weather_station_precipitation_mm Precipitation in millimeters
# TYPE weather_station_precipitation_mm gauge
weather_station_precipitation_mm{station="{{ .Station }}"} {{ .Precipitation }} {{ .TS }}{{ if .ConditionCode }}
# HELP weather_station_condition Weather condition indicator
# TYPE weather_station_condition gauge
weather_station_condition{station="{{ .Station }}",code="{{ .ConditionCode }}"} 1 {{ .TS }}{{ end }}
`
)

var (
	_tpl    = template.Must(template.New("prom").Parse(_promTemplate))
	_listen = flag.String("l", "127.0.0.1:9011", "listen on")
)

func main() {
	flag.Parse()
	log.Printf("Listening on %s\n", *_listen)
	log.Fatal((&http.Server{
		Addr:    *_listen,
		Handler: http.HandlerFunc(handler),
	}).ListenAndServe())
}

type observation struct {
	ObservationTimeUtc   string   `json:"observationTimeUtc"`
	AirTemperature       float64  `json:"airTemperature"`
	FeelsLikeTemperature float64  `json:"feelsLikeTemperature"`
	WindSpeed            float64  `json:"windSpeed"`
	WindGust             float64  `json:"windGust"`
	WindDirection        float64  `json:"windDirection"`
	CloudCover           *float64 `json:"cloudCover"`
	SeaLevelPressure     float64  `json:"seaLevelPressure"`
	RelativeHumidity     float64  `json:"relativeHumidity"`
	Precipitation        float64  `json:"precipitation"`
	ConditionCode        *string  `json:"conditionCode"`

	// template variables
	TS      int64
	Station string
}

func handler(w http.ResponseWriter, r *http.Request) {
	observations, err := getObservations(time.Now().UTC(), _station)
	if err != nil {
		log.Printf("Error getting observations: %v\n", err)
		http.Error(w, fmt.Sprintf("Internal error: %v", err.Error()), 500)
		return
	}
	w.Header().Add("Content-Type", "text/plain; version=0.0.4")

	bw := bufio.NewWriter(w)
	defer bw.Flush()

	for _, observation := range observations {

		ts, err := time.ParseInLocation(
			time.DateTime,
			observation.ObservationTimeUtc,
			time.UTC,
		)
		if err != nil {
			log.Printf("error parsing time %q: %v\n", observation.ObservationTimeUtc, err)
			return
		}
		observation.TS = ts.UnixMilli()
		observation.Station = _station

		if err := _tpl.Execute(bw, observation); err != nil {
			log.Printf("error executing template: %v", err)
			return
		}
	}
	bw.WriteString("\n")
}

func getObservations(date time.Time, station string) ([]observation, error) {
	url := fmt.Sprintf(_urlTemplate, station, date.Format(time.DateOnly))
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "jakstys.lt/contact")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("get %q: %w", url, err)
	}

	defer func() {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("got non-200 http status code %d", resp.StatusCode)
	}

	decoder := json.NewDecoder(resp.Body)
	var incoming struct {
		Observations []observation `json:"observations"`
	}
	if err := decoder.Decode(&incoming); err != nil {
		return nil, fmt.Errorf("json decode: %w", err)
	}

	return incoming.Observations, nil
}
