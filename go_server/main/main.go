package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// ==================== 主函数 ====================

func printBanner(debug bool) {
	logPlain("")
	logPlain(strings.Repeat("=", 60))
	logInfo("🚀 Bilibili API Server 启动中...")
	if debug {
		logInfo("调试模式: 开启 (DEBUG=true)")
	} else {
		logInfo("调试模式: 关闭 (设置 DEBUG=true 开启)")
	}
	logPlain(strings.Repeat("=", 60))
	logPlain("")
}

func printEndpoints(host, port string) {
	logPlain("")
	logPlain(strings.Repeat("=", 60))
	logSuccess("✅ 服务器运行于 http://%s:%s", host, port)
	logInfo("可用接口列表:")
	for _, e := range startupEndpoints {
		logPlain("  " + e)
	}
	logPlain(strings.Repeat("=", 60))
	logPlain("")
	logInfo("服务器已就绪，等待请求...")
	logPlain("")
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}
	debug := os.Getenv("DEBUG") == "true"
	host := "127.0.0.1"
	if debug {
		host = "0.0.0.0"
	}

	printBanner(debug)

	globalClient = NewBilibiliClient("", "")

	// 启动时加载本地 Cookie 缓存：loadCookieStore 内部会写字段并发布快照
	if cs, err := loadCookies(); err == nil {
		globalClient.loadCookieStore(cs)
		logInfo("已加载本地 Cookie 缓存")
	} else {
		logWarn("未加载到本地 Cookie 缓存: %s", err.Error())
	}

	globalClient.Init()

	mux := http.NewServeMux()
	setupRoutes(mux)

	handler := recoverMiddleware(loggingMiddleware(mux))

	// 关键：给 HTTP 服务器配置超时，避免慢客户端 / 半开连接耗尽 goroutine 与 fd
	srv := &http.Server{
		Addr:              host + ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1 MiB
	}

	// 退出：用 Shutdown 替代 os.Exit，让正在处理的请求有机会完成
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	shutdownDone := make(chan struct{})

	go func() {
		defer close(shutdownDone)
		sig := <-sigChan
		logPlain("")
		logWarn("收到 %s 信号，正在关闭...", sig.String())

		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := srv.Shutdown(shutdownCtx); err != nil {
			logWarn("优雅关闭超时，强制结束: %s", err.Error())
			_ = srv.Close()
		} else {
			logSuccess("服务器已关闭")
		}
	}()

	printEndpoints(host, port)

	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logError("❌ 启动失败: %s", err.Error())
		_ = asyncLogFlush(asyncLogShutdownTimeout)
		os.Exit(1)
	} else if err == http.ErrServerClosed {
		select {
		case <-shutdownDone:
		case <-time.After(11 * time.Second):
			logWarn("等待关闭流程完成超时")
		}
	}
	logInfo("服务器主循环已退出")
	_ = asyncLogFlush(asyncLogShutdownTimeout)
}
