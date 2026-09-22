package traffic

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	agent "runman-agent/proto/agent"
	"runman-agent/config"
	"runman-agent/db"
	"runman-agent/manager"
)

type mockVMManager struct {
	manager.VMManager
	vms      []*agent.VMSummary
	netStats map[string]*manager.VMNetStats
}

func (m *mockVMManager) ListVMs(ctx context.Context) ([]*agent.VMSummary, error) {
	return m.vms, nil
}

func (m *mockVMManager) GetVMNetStats(ctx context.Context, vmID string) (*manager.VMNetStats, error) {
	if s, ok := m.netStats[vmID]; ok {
		return s, nil
	}
	return nil, fmt.Errorf("vm %s net stats not found", vmID)
}

func setupTestEnv(t *testing.T) (*Service, *mockVMManager, *db.DB) {
	t.Helper()
	tmpDir := t.TempDir()

	dbPath := filepath.Join(tmpDir, "test.db")
	database, err := db.Init(dbPath)
	if err != nil {
		t.Fatalf("failed to init test db: %v", err)
	}

	cfgPath := filepath.Join(tmpDir, "config.json")
	if err := os.WriteFile(cfgPath, []byte(`{"traffic_reset_day": 1}`), 0644); err != nil {
		t.Fatalf("failed to write test config: %v", err)
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("failed to load test config: %v", err)
	}

	mockMgr := &mockVMManager{
		vms: []*agent.VMSummary{
			{VmId: "vm-test-1"},
		},
		netStats: make(map[string]*manager.VMNetStats),
	}

	svc := NewService(mockMgr, database, cfg)
	return svc, mockMgr, database
}

// 1. 单调递增：增量等量累计
func TestTraffic_MonotonicIncrease(t *testing.T) {
	svc, mockMgr, database := setupTestEnv(t)
	ctx := context.Background()

	// 初始采样
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  1000,
		OutBytes: 500,
	}
	svc.syncOnce(ctx)

	rec, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if rec.RawIn != 1000 || rec.RawOut != 500 {
		t.Errorf("expected RawIn=1000, RawOut=500; got %d, %d", rec.RawIn, rec.RawOut)
	}
	if rec.TotalIn != 0 || rec.TotalOut != 0 {
		t.Errorf("initial TotalIn/TotalOut should be 0; got %d, %d", rec.TotalIn, rec.TotalOut)
	}

	// 第二轮：增加 500 in, 300 out
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  1500,
		OutBytes: 800,
	}
	svc.syncOnce(ctx)

	rec, err = database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if rec.TotalIn != 500 || rec.TotalOut != 300 {
		t.Errorf("expected TotalIn=500, TotalOut=300; got TotalIn=%d, TotalOut=%d", rec.TotalIn, rec.TotalOut)
	}
	if rec.MonthIn != 500 || rec.MonthOut != 300 {
		t.Errorf("expected MonthIn=500, MonthOut=300; got MonthIn=%d, MonthOut=%d", rec.MonthIn, rec.MonthOut)
	}
	if rec.RawIn != 1500 || rec.RawOut != 800 {
		t.Errorf("expected RawIn=1500, RawOut=800; got %d, %d", rec.RawIn, rec.RawOut)
	}

	// 第三轮：再增加 700 in, 300 out
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  2200,
		OutBytes: 1100,
	}
	svc.syncOnce(ctx)

	rec, err = database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if rec.TotalIn != 1200 || rec.TotalOut != 600 {
		t.Errorf("expected TotalIn=1200, TotalOut=600; got TotalIn=%d, TotalOut=%d", rec.TotalIn, rec.TotalOut)
	}
	if rec.MonthIn != 1200 || rec.MonthOut != 600 {
		t.Errorf("expected MonthIn=1200, MonthOut=600; got MonthIn=%d, MonthOut=%d", rec.MonthIn, rec.MonthOut)
	}
}

// 2. 零值样本：采样异常全 0 且库里已有 raw 值时跳过，不写库，后续恢复时不重复累加
func TestTraffic_ZeroSampleSkipped(t *testing.T) {
	svc, mockMgr, database := setupTestEnv(t)
	ctx := context.Background()

	// 建立有效初始采样
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  2000,
		OutBytes: 1000,
	}
	svc.syncOnce(ctx)

	// 第二轮增量
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  2500,
		OutBytes: 1200,
	}
	svc.syncOnce(ctx)

	recBefore, _ := database.GetTraffic("vm-test-1")
	if recBefore.TotalIn != 500 || recBefore.RawIn != 2500 {
		t.Fatalf("setup failed: TotalIn=%d, RawIn=%d", recBefore.TotalIn, recBefore.RawIn)
	}

	// 模拟零值样本（驱动返回 0，如 stats 抖动或采集异常）
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  0,
		OutBytes: 0,
	}
	svc.syncOnce(ctx)

	// 检验：此轮必须被跳过，数据库不被覆写为 0，RawIn 保持 2500
	recAfterZero, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if recAfterZero.RawIn != 2500 || recAfterZero.RawOut != 1200 {
		t.Errorf("zero sample should be skipped! RawIn/RawOut modified: got RawIn=%d, RawOut=%d", recAfterZero.RawIn, recAfterZero.RawOut)
	}
	if recAfterZero.TotalIn != 500 || recAfterZero.TotalOut != 200 {
		t.Errorf("TotalIn/TotalOut modified during zero sample: got %d, %d", recAfterZero.TotalIn, recAfterZero.TotalOut)
	}

	// 下一轮恢复正常并产生微量增长：2600 in, 1250 out
	// 若之前未跳过且写入了 0，此轮 delta 会变成 2600-0=2600（全量重加虚高）；
	// 修复后 delta 应为 2600-2500=100。
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  2600,
		OutBytes: 1250,
	}
	svc.syncOnce(ctx)

	recRecovered, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if recRecovered.TotalIn != 600 { // 500 + 100
		t.Errorf("expected TotalIn=600 after recovery, got %d (possible double count bug!)", recRecovered.TotalIn)
	}
	if recRecovered.TotalOut != 250 { // 200 + 50
		t.Errorf("expected TotalOut=250 after recovery, got %d", recRecovered.TotalOut)
	}
	if recRecovered.RawIn != 2600 || recRecovered.RawOut != 1250 {
		t.Errorf("expected RawIn=2600, RawOut=1250; got %d, %d", recRecovered.RawIn, recRecovered.RawOut)
	}
}

// 3. 计数器回退（如重启）：delta 钳制为 0，杜绝全量重加
func TestTraffic_CounterRollbackClampedToZero(t *testing.T) {
	svc, mockMgr, database := setupTestEnv(t)
	ctx := context.Background()

	// 初始采样
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  100000,
		OutBytes: 50000,
	}
	svc.syncOnce(ctx)

	// 累加 20000 in, 10000 out
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  120000,
		OutBytes: 60000,
	}
	svc.syncOnce(ctx)

	rec, _ := database.GetTraffic("vm-test-1")
	if rec.TotalIn != 20000 || rec.TotalOut != 10000 {
		t.Fatalf("setup failed: TotalIn=%d, TotalOut=%d", rec.TotalIn, rec.TotalOut)
	}

	// 容器重启：计数器归小（例如重启后仅产生 300 in, 100 out）
	// 旧逻辑：deltaIn < 0 -> deltaIn = 300, 导致重启前后的总数虽未爆棚但直接加上了新 raw；
	// 更致命的是若之前 raw 被写 0，旧逻辑会把历史所有流量全量重加。
	// 新逻辑：delta 钳制为 0，累计量不变，Raw 刷新为当前值
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  300,
		OutBytes: 100,
	}
	svc.syncOnce(ctx)

	recRollback, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if recRollback.TotalIn != 20000 || recRollback.TotalOut != 10000 {
		t.Errorf("TotalIn/TotalOut must not increase on rollback! got TotalIn=%d, TotalOut=%d", recRollback.TotalIn, recRollback.TotalOut)
	}
	if recRollback.MonthIn != 20000 || recRollback.MonthOut != 10000 {
		t.Errorf("MonthIn/MonthOut must not increase on rollback! got MonthIn=%d, MonthOut=%d", recRollback.MonthIn, recRollback.MonthOut)
	}
	if recRollback.RawIn != 300 || recRollback.RawOut != 100 {
		t.Errorf("RawIn/RawOut should update to new base; got RawIn=%d, RawOut=%d", recRollback.RawIn, recRollback.RawOut)
	}

	// 重启后继续单调递增：从 300 -> 500 (增量 200), 100 -> 150 (增量 50)
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  500,
		OutBytes: 150,
	}
	svc.syncOnce(ctx)

	recAfter, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}
	if recAfter.TotalIn != 20200 || recAfter.TotalOut != 10050 {
		t.Errorf("expected TotalIn=20200, TotalOut=10050; got %d, %d", recAfter.TotalIn, recAfter.TotalOut)
	}
	if recAfter.MonthIn != 20200 || recAfter.MonthOut != 10050 {
		t.Errorf("expected MonthIn=20200, MonthOut=10050; got %d, %d", recAfter.MonthIn, recAfter.MonthOut)
	}
}

// 4. 跨周期重置：Month 变更时重置 MonthIn/MonthOut，而 TotalIn/TotalOut 持续累计
func TestTraffic_CrossCycleReset(t *testing.T) {
	svc, mockMgr, database := setupTestEnv(t)
	ctx := context.Background()

	// 手工写入一条上个周期的记录
	oldTraffic := &db.Traffic{
		VMID:      "vm-test-1",
		RawIn:     10000,
		RawOut:    5000,
		TotalIn:   8000,
		TotalOut:  4000,
		Month:     "2000-01-01", // 过去的周期
		MonthIn:   8000,
		MonthOut:  4000,
		UpdatedAt: time.Now().Add(-24 * time.Hour),
	}
	if err := database.SaveTraffic(oldTraffic); err != nil {
		t.Fatalf("failed to save old traffic: %v", err)
	}

	// 新一轮采样：增加 2000 in, 1000 out
	mockMgr.netStats["vm-test-1"] = &manager.VMNetStats{
		VMID:     "vm-test-1",
		InBytes:  12000,
		OutBytes: 6000,
	}
	svc.syncOnce(ctx)

	rec, err := database.GetTraffic("vm-test-1")
	if err != nil {
		t.Fatalf("failed to get traffic: %v", err)
	}

	// Total 必须继续累计：8000 + 2000 = 10000, 4000 + 1000 = 5000
	if rec.TotalIn != 10000 || rec.TotalOut != 5000 {
		t.Errorf("expected TotalIn=10000, TotalOut=5000; got TotalIn=%d, TotalOut=%d", rec.TotalIn, rec.TotalOut)
	}

	// Month 必须被刷新到当前周期
	if rec.Month == "2000-01-01" {
		t.Errorf("Month should have updated to current cycle, still 2000-01-01")
	}

	// Month 累计量必须重置并仅包含本周期增量：2000 in, 1000 out
	if rec.MonthIn != 2000 || rec.MonthOut != 1000 {
		t.Errorf("expected MonthIn=2000, MonthOut=1000 after reset; got MonthIn=%d, MonthOut=%d", rec.MonthIn, rec.MonthOut)
	}
}
