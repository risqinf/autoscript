package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/handler"
	"github.com/risqinf/autoscript-api/internal/middleware"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/router"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func main() {
	// Logger
	logger := zerolog.New(os.Stdout).With().Timestamp().Logger()

	// Config
	cfg, err := config.Load()
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to load config")
	}

	// Ensure API database directory exists
	apiDBDir := "/etc/api"
	if err := os.MkdirAll(apiDBDir, 0700); err != nil {
		logger.Fatal().Err(err).Msg("failed to create API database directory")
	}

	// Open API database
	apiDB, err := sql.Open("sqlite", cfg.APIDatabasePath)
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to open API database")
	}
	defer apiDB.Close()

	// Configure API database
	apiDB.SetMaxOpenConns(1)
	apiDB.SetMaxIdleConns(1)
	apiDB.SetConnMaxLifetime(0)

	// Initialize API schema
	apiRepoImpl := repository.NewAPIRepositoryImpl(apiDB)
	if err := apiRepoImpl.InitSchema(); err != nil {
		logger.Fatal().Err(err).Msg("failed to initialize API schema")
	}
	apiRepo := apiRepoImpl

	// Open main database
	mainDB, err := sql.Open("sqlite", cfg.MainDatabasePath)
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to open main database")
	}
	defer mainDB.Close()

	// Configure main database
	mainDB.SetMaxOpenConns(1)
	mainDB.SetMaxIdleConns(1)
	mainDB.SetConnMaxLifetime(0)

	// Validator
	val := validator.New()

	// Repositories
	accountRepo := repository.NewAccountRepository(mainDB)

	// Services
	accountSvc := service.NewAccountService(accountRepo, apiRepo, cfg, &logger)
	xraySvc := service.NewXrayService(cfg, &logger)
	monitorSvc := service.NewMonitorService(accountRepo, cfg, &logger)

	// Handlers
	accountHdlr := handler.NewAccountHandler(accountSvc, xraySvc, val, &logger)
	monitorHdlr := handler.NewMonitorHandler(monitorSvc, &logger)
	systemHdlr := handler.NewSystemHandler(monitorSvc, &logger)

	// Middleware
	authMw := middleware.NewAuthMiddleware(apiRepo, &logger)
	loggerMw := middleware.NewLoggerMiddleware(&logger)
	rateLimitMw := middleware.NewRateLimiter(apiRepo, cfg.RateLimit, cfg.RateLimitWindow, &logger)

	// Router
	r := router.New(authMw, loggerMw, rateLimitMw)
	r.RegisterAccountRoutes(accountHdlr)
	r.RegisterMonitorRoutes(monitorHdlr)
	r.RegisterSystemRoutes(systemHdlr)

	// Server
	srv := r.Server(cfg.ListenAddress)

	// Start server
	go func() {
		logger.Info().Str("addr", cfg.ListenAddress).Msg("starting API server")
		if err := srv.ListenAndServe(cfg.ListenAddress); err != nil {
			logger.Fatal().Err(err).Msg("server failed to start")
		}
	}()

	// Generate default token if none exists
	tokens, err := apiRepo.ListTokens(context.Background())
	if err != nil {
		logger.Warn().Err(err).Msg("failed to check tokens")
	} else if len(tokens) == 0 {
		token, err := apiRepo.CreateToken(context.Background(), "default")
		if err != nil {
			logger.Warn().Err(err).Msg("failed to create default token")
		} else {
			logger.Info().Str("token", token).Msg("default API token created")
			fmt.Printf("\n=== DEFAULT API TOKEN ===\n%s\n========================\n\n", token)
		}
	}

	// Graceful shutdown
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
