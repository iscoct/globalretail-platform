package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthEndpoint(t *testing.T) {
	r := newRouter()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var body map[string]any
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("expected status=ok, got %v", body["status"])
	}
}

func TestVersionEndpoint(t *testing.T) {
	r := newRouter()
	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	body := map[string]string{}
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["name"] != "inventory-api" {
		t.Errorf("expected name=inventory-api, got %q", body["name"])
	}
}

func TestInventoryEndpoint_Hit(t *testing.T) {
	r := newRouter()
	req := httptest.NewRequest(http.MethodGet, "/inventory/GR-SHIRT-001", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	body := Item{}
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body.SKU != "GR-SHIRT-001" {
		t.Errorf("expected SKU=GR-SHIRT-001, got %q", body.SKU)
	}
	if body.Stock < 0 {
		t.Errorf("stock should not be negative: %d", body.Stock)
	}
}

func TestInventoryEndpoint_Miss(t *testing.T) {
	r := newRouter()
	req := httptest.NewRequest(http.MethodGet, "/inventory/DOES-NOT-EXIST", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestMetricsEndpoint(t *testing.T) {
	r := newRouter()

	// Warm up the histogram + counter so /metrics has data.
	for i := 0; i < 3; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/health", nil))
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/inventory/GR-SHIRT-001", nil))
	w = httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/inventory/DOES-NOT-EXIST", nil))

	w = httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	body := w.Body.String()

	// At a minimum, the registry should expose:
	//   - the standard Go process/runtime collectors
	//   - our HTTP histogram with the app label
	//   - the inventory_lookups_total counter with hit + miss outcomes
	for _, frag := range []string{
		"go_goroutines",
		"process_cpu_seconds_total",
		`http_request_duration_seconds_bucket{app="inventory-api"`,
		`inventory_lookups_total{app="inventory-api",outcome="hit"`,
		`inventory_lookups_total{app="inventory-api",outcome="miss"`,
	} {
		if !strings.Contains(body, frag) {
			t.Errorf("/metrics output missing %q", frag)
		}
	}
}
