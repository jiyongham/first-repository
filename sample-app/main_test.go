package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	healthHandler(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
}

func TestRootHandler(t *testing.T) {
	version = "test-v1"
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	rootHandler(w, req)
	if !strings.Contains(w.Body.String(), "test-v1") {
		t.Errorf("expected version in body, got: %s", w.Body.String())
	}
}
