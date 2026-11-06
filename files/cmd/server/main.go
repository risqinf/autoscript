package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/risqinf/autoscript-api/internal/cache"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/handler"
	"github.com/risqinf/autoscript-api/internal/middleware"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/router"
	"github.com/risqinf/autoscript-api/internal/security"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

// Version is injected at build time via -ldflags "-X main.Version=v5.6.1".
var Version = "v5.6.1"

func main() {
	showVersion := flag.Bool("version", false, "Print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Printf("autoscript-api %s\n", Version)
		return
	}

	logger := zerolog.New(os.Stdout).With().Timestamp().Str("version", Version).Logger()

	cfg, err := config.Load()
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to load config")
	}

	// Open API database (single writer pool; hot path uses atomic memory cache)
	apiDB, err := sql.Open("sqlite", config.SQLiteDSN(cfg.APIDatabasePath, false))
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to open API database")
	}
	defer apiDB.Close()

	apiDB.SetMaxOpenConns(1)
	apiDB.SetMaxIdleConns(1)
	apiDB.SetConnMaxLifetime(0)

	apiRepoImpl := repository.NewAPIRepositoryImpl(apiDB)
	if err := apiRepoImpl.InitSchema(); err != nil {
		logger.Fatal().Err(err).Msg("failed to initialize API schema")
	}
	apiRepo := apiRepoImpl

	// Ensure Bearer token in /etc/api/key and api.db are synchronized
	activeToken, err := apiRepo.SyncKeyFile(context.Background(), cfg.APIKeyFile)
	if err != nil {
		logger.Warn().Err(err).Msg("failed to synchronize default API token")
	} else if activeToken != "" {
		logger.Info().Msg("API Bearer token & SHA-256 HMAC secret initialized")
	}

	// Open Main VPN database with separated WAL Writer (1 conn) + Concurrent Readers (N conns)
	mainWriteDB, err := sql.Open("sqlite", config.SQLiteDSN(cfg.MainDatabasePath, false))
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to open main write database")
	}
	defer mainWriteDB.Close()
	mainWriteDB.SetMaxOpenConns(1)
	mainWriteDB.SetMaxIdleConns(1)
	mainWriteDB.SetConnMaxLifetime(0)

	// Ensure WAL schema is initialized on mainWriteDB BEFORE opening read-only pool connections
	tempWriteRepo := repository.NewAccountRepository(mainWriteDB)
	if err := tempWriteRepo.InitSchema(); err != nil {
		logger.Fatal().Err(err).Msg("failed to initialize main account schema")
	}

	mainReadDB, err := sql.Open("sqlite", config.SQLiteDSN(cfg.MainDatabasePath, true))
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to open main read database")
	}
	defer mainReadDB.Close()
	readConns := cfg.ReadPoolSize()
	mainReadDB.SetMaxOpenConns(readConns)
	mainReadDB.SetMaxIdleConns(readConns)
	mainReadDB.SetConnMaxLifetime(0)

	accountRepo := repository.NewAccountRepositoryWithPools(mainReadDB, mainWriteDB)

	// Shared Singleflight Snapshot Cache
	snapCache := cache.NewSnapshotCache()
	val := validator.New()

	// Services
	xraySvc := service.NewXrayService(cfg, &logger)
	accountSvc := service.NewAccountServiceFull(accountRepo, apiRepo, xraySvc, snapCache, cfg, &logger)
	monitorSvc := service.NewMonitorServiceWithCache(accountRepo, cfg, snapCache, &logger)

	// Handlers
	accountHdlr := handler.NewAccountHandlerWithConfig(accountSvc, xraySvc, val, cfg, &logger)
	monitorHdlr := handler.NewMonitorHandlerWithXray(monitorSvc, xraySvc, &logger)
	systemHdlr := handler.NewSystemHandlerFull(monitorSvc, accountSvc, xraySvc, val, &logger)

	// Multi-Layer SHA-256 Security & High-Throughput Middleware
	verifier := security.NewVerifier(apiRepo, cfg)
	defer verifier.Close()

	authMw := middleware.NewAuthMiddlewareWithVerifier(verifier, &logger)
	loggerMw := middleware.NewLoggerMiddlewareWithRepo(apiRepo, &logger)
	defer loggerMw.Close()
	rateLimitMw := middleware.NewHighThroughputRateLimiter(cfg.RateLimit, cfg.AuthBurstLimit, cfg.RateLimitWindow, &logger)
	defer rateLimitMw.Close()

	// Router & Server
	r := router.NewWithConfig(authMw, loggerMw, rateLimitMw, cfg)
	r.RegisterAccountRoutes(accountHdlr)
	r.RegisterMonitorRoutes(monitorHdlr)
	r.RegisterSystemRoutes(systemHdlr)

	srv := r.Server(cfg.ListenAddress)

	go func() {
		logger.Info().
			Str("addr", cfg.ListenAddress).
			Str("security_mode", cfg.SecurityMode).
			Int("max_concurrency", cfg.MaxConcurrency).
			Int("read_pool", readConns).
			Msg("starting Autoscript Enterprise API Server")
		if err := srv.ListenAndServe(cfg.ListenAddress); err != nil {
			logger.Fatal().Err(err).Msg("server failed to start")
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info().Msg("shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.ShutdownWithContext(ctx); err != nil {
		logger.Error().Err(err).Msg("server forced to shutdown")
	}
	logger.Info().Msg("server stopped")
}
