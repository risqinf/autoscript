package router_test

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/risqinf/autoscript-api/internal/cache"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/handler"
	"github.com/risqinf/autoscript-api/internal/middleware"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/router"
	"github.com/risqinf/autoscript-api/internal/security"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	"github.com/valyala/fasthttp"
	_ "modernc.org/sqlite"
)

type testAPIEnv struct {
	rt         *router.Router
	token      string
	secret     string
	xrayCfg    string
	accessLog  string
	mainDB     *sql.DB
	nonceCount atomic.Uint64
}

func setupTestAPI(t *testing.T) *testAPIEnv {
	t.Helper()
	t.Setenv("AUTOSCRIPT_TEST_MODE", "1")
	t.Setenv("AUTOSCRIPT_TEST_SKIP_OS_USERS", "1")

	tmpDir := t.TempDir()
	apiDBPath := filepath.Join(tmpDir, "api.db")
	mainDBPath := filepath.Join(tmpDir, "xray.db")
	keyFile := filepath.Join(tmpDir, "key")
	secFile := filepath.Join(tmpDir, "secret")
	domainFile := filepath.Join(tmpDir, "domain")
	xrayCfgPath := filepath.Join(tmpDir, "config.json")
	accessLogPath := filepath.Join(tmpDir, "access.log")
	dnsLogPath := filepath.Join(tmpDir, "dns.log")
	geoCachePath := filepath.Join(tmpDir, "geoip.cache")

	secret := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	_ = os.WriteFile(domainFile, []byte("vpn.risqinf.dev\n"), 0600)
	_ = os.WriteFile(secFile, []byte(secret+"\n"), 0600)

	// Write realistic multi-inbound Xray config (WS + gRPC + VMess + Trojan)
	initialXray := `{
  "log": { "access": "` + accessLogPath + `", "loglevel": "warning" },
  "inbounds": [
    { "tag": "vless-ws", "protocol": "vless", "settings": { "clients": [], "decryption": "none" } },
    { "tag": "vless-grpc", "protocol": "vless", "settings": { "clients": [], "decryption": "none" } },
    { "tag": "vmess-ws", "protocol": "vmess", "settings": { "clients": [] } },
    { "tag": "trojan-ws", "protocol": "trojan", "settings": { "clients": [] } }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}`
	if err := os.WriteFile(xrayCfgPath, []byte(initialXray), 0600); err != nil {
		t.Fatalf("write xray config: %v", err)
	}

	// Pre-populate GeoIP cache so tests run 100% offline & deterministic
	nowUnix := time.Now().Unix()
	geoSeed := fmt.Sprintf("203.0.113.10|%d|Telkomsel Indonesia|Jakarta, Indonesia\n198.51.100.25|%d|Biznet Networks|Bandung, Indonesia\n", nowUnix, nowUnix)
	_ = os.WriteFile(geoCachePath, []byte(geoSeed), 0600)

	cfg := &config.Config{
		ListenAddress:    "127.0.0.1:0",
		MaxConcurrency:   65536,
		MaxBulkSize:      1000,
		APIDatabasePath:  apiDBPath,
		MainDatabasePath: mainDBPath,
		APIKeyFile:       keyFile,
		APISecretFile:    secFile,
		APISecret:        secret,
		SecurityMode:     "strict",
		MaxSkewSec:       300,
		DomainFile:       domainFile,
		XrayConfig:       xrayCfgPath,
		XrayBinary:       filepath.Join(tmpDir, "nonexistent-xray-bin"),
		XrayAccessLog:    accessLogPath,
		XrayAPIAddress:   "127.0.0.1:10085",
		SSHWSAPI:         "",
		DNSLogFile:       dnsLogPath,
		GeoIPCacheFile:   geoCachePath,
		RateLimit:        50000,
		AuthBurstLimit:   500000,
		RateLimitWindow:  60,
	}

	apiDB, err := sql.Open("sqlite", apiDBPath)
	if err != nil {
		t.Fatalf("open apiDB: %v", err)
	}
	t.Cleanup(func() { _ = apiDB.Close() })
	apiDB.SetMaxOpenConns(1)

	apiRepo := repository.NewAPIRepositoryImpl(apiDB)
	if err := apiRepo.InitSchema(); err != nil {
		t.Fatalf("init api schema: %v", err)
	}
	token, err := apiRepo.SyncKeyFile(t.Context(), keyFile)
	if err != nil {
		t.Fatalf("sync key file: %v", err)
	}

	mainWriteDB, err := sql.Open("sqlite", mainDBPath)
	if err != nil {
		t.Fatalf("open mainWriteDB: %v", err)
	}
	t.Cleanup(func() { _ = mainWriteDB.Close() })
	mainWriteDB.SetMaxOpenConns(1)

	mainReadDB, err := sql.Open("sqlite", mainDBPath)
	if err != nil {
		t.Fatalf("open mainReadDB: %v", err)
	}
	t.Cleanup(func() { _ = mainReadDB.Close() })
	mainReadDB.SetMaxOpenConns(4)

	accRepo := repository.NewAccountRepositoryWithPools(mainReadDB, mainWriteDB)
	if err := accRepo.InitSchema(); err != nil {
		t.Fatalf("init main schema: %v", err)
	}

	logger := zerolog.Nop()
	snap := cache.NewSnapshotCache()
	val := validator.New()

	xraySvc := service.NewXrayService(cfg, &logger)
	accSvc := service.NewAccountServiceFull(accRepo, apiRepo, xraySvc, snap, cfg, &logger)
	monSvc := service.NewMonitorServiceWithCache(accRepo, cfg, snap, &logger)

	accHdlr := handler.NewAccountHandlerWithConfig(accSvc, xraySvc, val, cfg, &logger)
	monHdlr := handler.NewMonitorHandler(monSvc, &logger)
	sysHdlr := handler.NewSystemHandlerFull(monSvc, accSvc, xraySvc, val, &logger)

	verifier := security.NewVerifier(apiRepo, cfg)
	t.Cleanup(func() { verifier.Close() })

	authMw := middleware.NewAuthMiddlewareWithVerifier(verifier, &logger)
	logMw := middleware.NewLoggerMiddlewareWithRepo(apiRepo, &logger)
	t.Cleanup(func() { logMw.Close() })
	rlMw := middleware.NewHighThroughputRateLimiter(cfg.RateLimit, cfg.AuthBurstLimit, cfg.RateLimitWindow, &logger)
	t.Cleanup(func() { rlMw.Close() })

	rt := router.NewWithConfig(authMw, logMw, rlMw, cfg)
	rt.RegisterAccountRoutes(accHdlr)
	rt.RegisterMonitorRoutes(monHdlr)
	rt.RegisterSystemRoutes(sysHdlr)

	return &testAPIEnv{
		rt:        rt,
		token:     token,
		secret:    secret,
		xrayCfg:   xrayCfgPath,
		accessLog: accessLogPath,
		mainDB:    mainWriteDB,
	}
}

func (e *testAPIEnv) executeSigned(method, rawURL string, body []byte, extraHeaders map[string]string) (int, []byte, map[string]string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return 0, nil, nil, fmt.Errorf("parse url %s: %w", rawURL, err)
	}

	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := fmt.Sprintf("test_nonce_%016x", e.nonceCount.Add(1))
	bodySHA, sig := security.SignRequest(method, u.Path, u.RawQuery, e.token, e.secret, ts, nonce, body)

	var ctx fasthttp.RequestCtx
	ctx.Request.Header.SetMethod(method)
	ctx.Request.SetRequestURI(rawURL)
	ctx.Request.Header.Set("Authorization", "Bearer "+e.token)
	ctx.Request.Header.Set("X-Content-SHA256", bodySHA)
	ctx.Request.Header.Set("X-Timestamp", ts)
	ctx.Request.Header.Set("X-Nonce", nonce)
	ctx.Request.Header.Set("X-Signature", sig)
	if len(body) > 0 {
		ctx.Request.Header.SetContentType("application/json")
		ctx.Request.SetBody(body)
	}
	for k, v := range extraHeaders {
		ctx.Request.Header.Set(k, v)
	}

	e.rt.Handler()(&ctx)

	// Verify mutual server response signature on every call!
	reqID := string(ctx.Response.Header.Peek("X-Request-ID"))
	respTS := string(ctx.Response.Header.Peek("X-Response-Timestamp"))
	respSHA := string(ctx.Response.Header.Peek("X-Response-SHA256"))
	srvSig := string(ctx.Response.Header.Peek("X-Server-Signature"))
	if !security.VerifyServerResponse(e.secret, reqID, respTS, respSHA, srvSig, ctx.Response.Body()) {
		return ctx.Response.StatusCode(), nil, nil, fmt.Errorf("server response signature invalid on %s %s (status=%d body=%s)",
			method, rawURL, ctx.Response.StatusCode(), string(ctx.Response.Body()))
	}

	hdrs := map[string]string{
		"X-Idempotent-Replay": string(ctx.Response.Header.Peek("X-Idempotent-Replay")),
		"X-Request-ID":        reqID,
		"X-Server-Signature":  srvSig,
	}
	bodyCopy := append([]byte(nil), ctx.Response.Body()...)
	return ctx.Response.StatusCode(), bodyCopy, hdrs, nil
}

func (e *testAPIEnv) doSigned(t testing.TB, method, rawURL string, body []byte, extraHeaders map[string]string) (int, []byte, map[string]string) {
	t.Helper()
	code, respBody, hdrs, err := e.executeSigned(method, rawURL, body, extraHeaders)
	if err != nil {
		t.Fatal(err)
	}
	return code, respBody, hdrs
}

func TestStandardEndpointSingleAndFlashSaleBulk(t *testing.T) {
	env := setupTestAPI(t)

	// 1. Public Health Check
	var healthCtx fasthttp.RequestCtx
	healthCtx.Request.Header.SetMethod("GET")
	healthCtx.Request.SetRequestURI("/api/health")
	env.rt.Handler()(&healthCtx)
	if healthCtx.Response.StatusCode() != 200 {
		t.Fatalf("expected 200 on /api/health, got %d", healthCtx.Response.StatusCode())
	}

	// 2. Cryptographic Auth Verify Endpoint
	code, verifyBody, _ := env.doSigned(t, "GET", "/api/auth/verify", nil, nil)
	if code != 200 {
		t.Fatalf("expected 200 on /api/auth/verify, got %d: %s", code, string(verifyBody))
	}

	// 3A. Standard Single Account Creation on POST /api/accounts/vless (100% compatible!)
	singlePayload := []byte(`{"username":"single_vless_01","quota":25,"limit_ip":2,"days":30}`)
	code, singleBody, _ := env.doSigned(t, "POST", "/api/accounts/vless", singlePayload, nil)
	if code != 201 {
		t.Fatalf("expected 201 on single POST /api/accounts/vless, got %d: %s", code, string(singleBody))
	}
	var singleResp struct {
		Success bool          `json:"success"`
		Data    model.Account `json:"data"`
	}
	if err := json.Unmarshal(singleBody, &singleResp); err != nil || singleResp.Data.Username != "single_vless_01" {
		t.Fatalf("expected standard single account object in data, got %s (err=%v)", string(singleBody), err)
	}

	// 3B. Flash-Sale Bulk Creation (500 accounts in 1 request!) on the EXACT SAME standard POST /api/accounts/vless!
	flashPayload := []byte(`{"count":500,"prefix":"flash_","quota":50,"limit_ip":2,"days":30}`)
	code, bulkBody, _ := env.doSigned(t, "POST", "/api/accounts/vless", flashPayload, map[string]string{
		"X-Idempotency-Key": "flash-sale-2026-batch-01",
	})
	if code != 201 {
		t.Fatalf("expected 201 on POST /api/accounts/vless (count=500), got %d: %s", code, string(bulkBody))
	}

	var bulkResp struct {
		Success bool                   `json:"success"`
		Data    model.BulkCreateResult `json:"data"`
	}
	if err := json.Unmarshal(bulkBody, &bulkResp); err != nil {
		t.Fatalf("unmarshal bulk response: %v", err)
	}
	if bulkResp.Data.CreatedCount != 500 || len(bulkResp.Data.Accounts) != 500 {
		t.Fatalf("expected 500 created accounts, got %d", bulkResp.Data.CreatedCount)
	}
	if bulkResp.Data.Accounts[0].Config == nil || bulkResp.Data.Accounts[0].Config.Transports["grpc_tls"] == "" {
		t.Fatalf("expected full multi-transport config links in bulk output")
	}

	// 3C. Top-Level JSON Array Bulk Creation on the EXACT SAME standard POST /api/accounts/vless!
	arrayPayload := []byte(`[{"username":"arr_user_01","quota":10,"limit_ip":1,"days":7},{"username":"arr_user_02","quota":10,"limit_ip":1,"days":7}]`)
	code, arrBody, _ := env.doSigned(t, "POST", "/api/accounts/vless", arrayPayload, nil)
	if code != 201 {
		t.Fatalf("expected 201 on array POST /api/accounts/vless, got %d: %s", code, string(arrBody))
	}

	// Verify Xray config.json contains all 503 clients (1 single + 500 flash + 2 array) in BOTH vless-ws & vless-grpc!
	rawXray, err := os.ReadFile(env.xrayCfg)
	if err != nil {
		t.Fatalf("read xray config: %v", err)
	}
	var parsedXray struct {
		Inbounds []struct {
			Tag      string `json:"tag"`
			Settings struct {
				Clients []map[string]interface{} `json:"clients"`
			} `json:"settings"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal(rawXray, &parsedXray); err != nil {
		t.Fatalf("parse updated xray config: %v", err)
	}
	if len(parsedXray.Inbounds[0].Settings.Clients) != 503 || len(parsedXray.Inbounds[1].Settings.Clients) != 503 {
		t.Fatalf("expected 503 clients in vless-ws & vless-grpc, got %d and %d",
			len(parsedXray.Inbounds[0].Settings.Clients), len(parsedXray.Inbounds[1].Settings.Clients))
	}

	// Retry same X-Idempotency-Key -> must return cached 201 with X-Idempotent-Replay: true without duplicating!
	codeReplay, _, replayHdr := env.doSigned(t, "POST", "/api/accounts/vless", flashPayload, map[string]string{
		"X-Idempotency-Key": "flash-sale-2026-batch-01",
	})
	if codeReplay != 201 || replayHdr["X-Idempotent-Replay"] != "true" {
		t.Fatalf("expected idempotent replay 201 with X-Idempotent-Replay=true, got %d", codeReplay)
	}

	// 3D. Standard Batch Renew (PUT /api/accounts/vless) & Batch Delete (DELETE /api/accounts/vless)
	code, renewBody, _ := env.doSigned(t, "PUT", "/api/accounts/vless", []byte(`{"usernames":["arr_user_01","arr_user_02"],"days":15}`), nil)
	if code != 200 {
		t.Fatalf("expected 200 on PUT /api/accounts/vless batch renew, got %d: %s", code, string(renewBody))
	}
	code, delBody, _ := env.doSigned(t, "DELETE", "/api/accounts/vless", []byte(`{"usernames":["arr_user_01","arr_user_02"]}`), nil)
	if code != 200 {
		t.Fatalf("expected 200 on DELETE /api/accounts/vless batch delete, got %d: %s", code, string(delBody))
	}

	// 3E. Standard Trial Endpoint (POST /api/trials/vless) for single AND bulk (`count: 10`)
	code, _, _ = env.doSigned(t, "POST", "/api/trials/vless", []byte(`{"duration":"1h","quota":2,"limit_ip":1}`), nil)
	if code != 201 {
		t.Fatalf("expected 201 on single trial POST /api/trials/vless, got %d", code)
	}
	code, _, _ = env.doSigned(t, "POST", "/api/trials/vless", []byte(`{"count":10,"duration":"2h","quota":2,"limit_ip":1}`), nil)
	if code != 201 {
		t.Fatalf("expected 201 on bulk trial POST /api/trials/vless (count=10), got %d", code)
	}

	// 4. SSH All-Protocol Quota Breakdown (OpenSSH, Dropbear, SSH SSL/TLS, SSH-WS, SlowDNS, OpenVPN)
	sshCreate := []byte(`{"username":"budi_ssh","password":"SafePass123!","quota":100,"limit_ip":3,"days":30}`)
	code, _, _ = env.doSigned(t, "POST", "/api/accounts/ssh", sshCreate, nil)
	if code != 201 {
		t.Fatalf("expected 201 creating budi_ssh, got %d", code)
	}

	// Seed per-protocol SSH counters in ssh_proto_usage
	_, err = env.mainDB.Exec(`
		INSERT INTO ssh_proto_usage (username, sub_protocol, rx_bytes, tx_bytes) VALUES
		('budi_ssh', 'openssh',  104857600, 52428800),
		('budi_ssh', 'ssh_ssl',  536870912, 268435456),
		('budi_ssh', 'ssh_ws',   268435456, 134217728),
		('budi_ssh', 'slowdns',  10485760,  5242880),
		('budi_ssh', 'openvpn',  1073741824, 536870912);
	`)
	if err != nil {
		t.Fatalf("insert ssh_proto_usage: %v", err)
	}

	code, sshQuotaBody, _ := env.doSigned(t, "GET", "/api/quota/ssh/budi_ssh", nil, nil)
	if code != 200 {
		t.Fatalf("expected 200 on /api/quota/ssh/budi_ssh, got %d: %s", code, string(sshQuotaBody))
	}
	var sshQuotaResp struct {
		Data model.SSHUserQuotaDetail `json:"data"`
	}
	if err := json.Unmarshal(sshQuotaBody, &sshQuotaResp); err != nil {
		t.Fatalf("unmarshal ssh quota: %v", err)
	}
	if sshQuotaResp.Data.Breakdown.OpenSSH.TotalBytes == 0 ||
		sshQuotaResp.Data.Breakdown.SSHSSL.TotalBytes == 0 ||
		sshQuotaResp.Data.Breakdown.OpenVPN.TotalBytes == 0 {
		t.Fatalf("expected non-zero OpenSSH, SSH_SSL, and OpenVPN counters, got %+v", sshQuotaResp.Data.Breakdown)
	}

	// 5. Live Monitor: Accessed Apps/Domains + Protocol/Transport + ISP + GeoIP
	targetUser := bulkResp.Data.Accounts[0].Account.Username
	nowLogTS := time.Now().Format("2006/01/02 15:04:05")
	logLines := fmt.Sprintf(
		"%s.120000 from 203.0.113.10:54122 accepted tcp:rr1---sn.googlevideo.com:443 [vless-ws -> direct] email: %s\n"+
			"%s.130000 from 203.0.113.10:54123 accepted tcp:api.openai.com:443 [vless-ws -> direct] email: %s\n"+
			"%s.140000 from 198.51.100.25:60111 accepted tcp:www.netflix.com:443 [vless-grpc -> direct] email: %s\n",
		nowLogTS, targetUser, nowLogTS, targetUser, nowLogTS, targetUser,
	)
	if err := os.WriteFile(env.accessLog, []byte(logLines), 0600); err != nil {
		t.Fatalf("write access.log: %v", err)
	}

	code, monBody, _ := env.doSigned(t, "GET", "/api/monitor/vless/"+targetUser+"/activity", nil, nil)
	if code != 200 {
		t.Fatalf("expected 200 on user activity monitor, got %d: %s", code, string(monBody))
	}
	var monResp struct {
		Data model.MonitorEntry `json:"data"`
	}
	if err := json.Unmarshal(monBody, &monResp); err != nil {
		t.Fatalf("unmarshal monitor entry: %v", err)
	}
	if monResp.Data.IPCount != 2 || len(monResp.Data.AccessedApps) < 3 {
		t.Fatalf("expected 2 IPs and >=3 accessed apps (YouTube, ChatGPT, Netflix), got %+v", monResp.Data)
	}
	if len(monResp.Data.ISPs) != 2 || len(monResp.Data.Locations) != 2 {
		t.Fatalf("expected ISP & GeoIP enrichment for both IPs, got ISPs=%v Locations=%v", monResp.Data.ISPs, monResp.Data.Locations)
	}

	// 6. System Info & Bandwidth endpoints
	code, sysBody, _ := env.doSigned(t, "GET", "/api/system/info", nil, nil)
	if code != 200 {
		t.Fatalf("expected 200 on /api/system/info, got %d: %s", code, string(sysBody))
	}
	code, bwBody, _ := env.doSigned(t, "GET", "/api/bandwidth", nil, nil)
	if code != 200 {
		t.Fatalf("expected 200 on /api/bandwidth, got %d: %s", code, string(bwBody))
	}
}

func TestHighConcurrencySingleflightStress(t *testing.T) {
	env := setupTestAPI(t)

	const totalRequests = 1000
	var wg sync.WaitGroup
	var okCount atomic.Int64
	var firstErr atomic.Value

	wg.Add(totalRequests)
	for i := 0; i < totalRequests; i++ {
		go func(idx int) {
			defer wg.Done()
			endpoint := "/api/system/info"
			switch idx % 4 {
			case 1:
				endpoint = "/api/quota/ssh"
			case 2:
				endpoint = "/api/monitor"
			case 3:
				endpoint = "/api/accounts?page=1&per_page=10"
			}
			code, _, _, err := env.executeSigned("GET", endpoint, nil, nil)
			if err != nil {
				firstErr.CompareAndSwap(nil, err.Error())
				return
			}
			if code == 200 {
				okCount.Add(1)
			}
		}(i)
	}
	wg.Wait()

	if e := firstErr.Load(); e != nil {
		t.Fatalf("concurrent request failed: %v", e)
	}
	if okCount.Load() != totalRequests {
		t.Fatalf("expected all %d concurrent signed requests to return 200, got %d", totalRequests, okCount.Load())
	}
}
