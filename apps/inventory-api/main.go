package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var startedAt = time.Now()

// --- Prometheus instrumentation ----------------------------------------------
// Per-app registry keeps OUR metrics scoped. Default labels carry the app
// name on every series — useful when one Prometheus scrapes many apps.
var (
	registry = prometheus.NewRegistry()

	httpRequestDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "Duration of HTTP requests in seconds.",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
	}, []string{"method", "route", "status"})

	inventoryLookupsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "inventory_lookups_total",
		Help: "Number of /inventory/{sku} lookups, by outcome (hit, miss).",
	}, []string{"outcome"})
)

func init() {
	// Apply a constant `app` label to every series in this registry so that
	// Prometheus can disambiguate this app from sample-app's series.
	wrapped := prometheus.WrapRegistererWith(prometheus.Labels{"app": "inventory-api"}, registry)
	wrapped.MustRegister(
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		collectors.NewGoCollector(),
		httpRequestDuration,
		inventoryLookupsTotal,
	)
}

// --- Middleware --------------------------------------------------------------

// statusCapturingWriter wraps http.ResponseWriter so we can read the status
// code we wrote. The stdlib's ResponseWriter doesn't expose the written
// status — and we need it for the Prometheus histogram label.
type statusCapturingWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusCapturingWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// instrument wraps a handler so every request lands in the histogram with
// the routed pattern (NOT the raw path) as the `route` label. Bounded
// cardinality — what Prometheus needs.
func instrument(routePattern string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusCapturingWriter{ResponseWriter: w, status: http.StatusOK}
		h(sw, r)
		httpRequestDuration.WithLabelValues(r.Method, routePattern, strconv.Itoa(sw.status)).Observe(time.Since(start).Seconds())
	}
}

// --- Handlers ----------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":        "ok",
		"uptimeSeconds": int(time.Since(startedAt).Seconds()),
	})
}

func handleVersion(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"name":    "inventory-api",
		"version": orDefault(os.Getenv("APP_VERSION"), "dev"),
		"commit":  orDefault(os.Getenv("APP_COMMIT"), "unknown"),
	})
}

func handleInventory(w http.ResponseWriter, r *http.Request) {
	sku := r.PathValue("sku")
	item, err := LookupSKU(sku)
	if err != nil {
		inventoryLookupsTotal.WithLabelValues("miss").Inc()
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found", "sku": sku})
		return
	}
	inventoryLookupsTotal.WithLabelValues("hit").Inc()
	writeJSON(w, http.StatusOK, item)
}

// --- Wiring ------------------------------------------------------------------

func newRouter() http.Handler {
	mux := http.NewServeMux()

	// Go 1.22+ ServeMux supports `{wildcard}` patterns. The `route` label in
	// our histogram uses the pattern, not the raw path, keeping label
	// cardinality bounded.
	mux.HandleFunc("GET /health", instrument("/health", handleHealth))
	mux.HandleFunc("GET /version", instrument("/version", handleVersion))
	mux.HandleFunc("GET /inventory/{sku}", instrument("/inventory/{sku}", handleInventory))

	// /metrics serves the Prometheus exposition format. NOT wrapped in the
	// histogram (scrape calls would otherwise show up as request volume).
	mux.Handle("GET /metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{Registry: registry}))

	return mux
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func main() {
	addr := ":" + orDefault(os.Getenv("PORT"), "3000")
	log.Printf("inventory-api listening on %s", addr)
	if err := http.ListenAndServe(addr, newRouter()); err != nil {
		log.Fatalf("server exited: %v", err)
	}
}
