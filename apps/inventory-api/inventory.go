package main

import (
	"errors"
	"strings"
)

// Item represents a row in the (fictional) inventory.
type Item struct {
	SKU       string `json:"sku"`
	Name      string `json:"name"`
	Stock     int    `json:"stock"`
	UpdatedAt string `json:"updatedAt"`
}

// ErrNotFound is returned when a SKU lookup misses.
var ErrNotFound = errors.New("inventory item not found")

// seedData is the mock catalogue. In a real service this would come from a
// DB or an upstream API; for the lab we keep it static so the demo is
// deterministic and the app has zero external dependencies at runtime.
//
// Pedagogical note: by keeping `seedData` `var` (not `const`) we leave room
// for a test to mutate it via `SetInventoryForTesting` — but it stays
// package-private so production code cannot accidentally tweak the catalogue.
var seedData = map[string]Item{
	"GR-SHIRT-001":   {SKU: "GR-SHIRT-001", Name: "GlobalRetail T-Shirt — Navy", Stock: 142, UpdatedAt: "2026-05-25T08:00:00Z"},
	"GR-SHIRT-002":   {SKU: "GR-SHIRT-002", Name: "GlobalRetail T-Shirt — White", Stock: 78, UpdatedAt: "2026-05-25T08:00:00Z"},
	"GR-MUG-001":     {SKU: "GR-MUG-001", Name: "GlobalRetail Coffee Mug", Stock: 12, UpdatedAt: "2026-05-25T08:00:00Z"},
	"GR-NOTEBOOK-A5": {SKU: "GR-NOTEBOOK-A5", Name: "GlobalRetail Notebook A5", Stock: 0, UpdatedAt: "2026-05-25T08:00:00Z"},
	"GR-PEN-RED":     {SKU: "GR-PEN-RED", Name: "GlobalRetail Pen — Red", Stock: 234, UpdatedAt: "2026-05-25T08:00:00Z"},
}

// LookupSKU returns the Item for an exact-match SKU. SKU matching is
// case-insensitive — typical retail expectation.
func LookupSKU(sku string) (Item, error) {
	if sku == "" {
		return Item{}, ErrNotFound
	}
	if item, ok := seedData[strings.ToUpper(sku)]; ok {
		return item, nil
	}
	return Item{}, ErrNotFound
}
