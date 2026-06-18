package main

import (
	"errors"
	"testing"
)

func TestLookupSKU(t *testing.T) {
	tests := []struct {
		name    string
		sku     string
		wantErr error
		wantSKU string
	}{
		{"exact match", "GR-SHIRT-001", nil, "GR-SHIRT-001"},
		{"case insensitive", "gr-shirt-001", nil, "GR-SHIRT-001"},
		{"unknown SKU", "GR-DOES-NOT-EXIST", ErrNotFound, ""},
		{"empty SKU", "", ErrNotFound, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := LookupSKU(tt.sku)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("expected error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.SKU != tt.wantSKU {
				t.Errorf("got SKU=%q, want %q", got.SKU, tt.wantSKU)
			}
		})
	}
}
