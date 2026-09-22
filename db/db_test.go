package db

import (
	"path/filepath"
	"testing"
	"time"
)

func TestDB_TrafficOperations(t *testing.T) {
	tmpDir := t.TempDir()
	dbPath := filepath.Join(tmpDir, "test.db")

	database, err := Init(dbPath)
	if err != nil {
		t.Fatalf("failed to init db: %v", err)
	}

	// 1. 保存与获取
	traffic := &Traffic{
		VMID:      "vm-1",
		RawIn:     100,
		RawOut:    200,
		TotalIn:   100,
		TotalOut:  200,
		Month:     "2026-09-01",
		MonthIn:   100,
		MonthOut:  200,
		UpdatedAt: time.Now(),
	}
	if err := database.SaveTraffic(traffic); err != nil {
		t.Fatalf("failed to save traffic: %v", err)
	}

	got, err := database.GetTraffic("vm-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if got.RawIn != 100 || got.RawOut != 200 || got.TotalIn != 100 || got.TotalOut != 200 {
		t.Errorf("unexpected traffic data: %+v", got)
	}

	// 2. 月度流量重置
	if err := database.ResetTrafficMonth("vm-1"); err != nil {
		t.Fatalf("failed to reset month traffic: %v", err)
	}
	gotReset, err := database.GetTraffic("vm-1")
	if err != nil {
		t.Fatalf("failed to get traffic after reset: %v", err)
	}
	if gotReset.MonthIn != 0 || gotReset.MonthOut != 0 {
		t.Errorf("expected month in/out to be 0; got %d, %d", gotReset.MonthIn, gotReset.MonthOut)
	}
	if gotReset.TotalIn != 100 || gotReset.TotalOut != 200 {
		t.Errorf("total in/out should remain intact; got %d, %d", gotReset.TotalIn, gotReset.TotalOut)
	}

	// 3. 删除流量记录
	if err := database.DeleteTraffic("vm-1"); err != nil {
		t.Fatalf("failed to delete traffic: %v", err)
	}
	_, err = database.GetTraffic("vm-1")
	if err == nil {
		t.Fatalf("expected error getting deleted traffic, got nil")
	}
}
