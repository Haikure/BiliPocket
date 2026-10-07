package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestProcessLockPath(t *testing.T) {
	dir := t.TempDir()
	path, err := processLockPath(dir, "08000")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "bilipocket-server-8000.lock"); path != want {
		t.Fatalf("锁路径 = %q，期望 %q", path, want)
	}
	for _, port := range []string{"", "0", "-1", "65536", "../8000", "8000/other", "http", " 8000"} {
		t.Run(port, func(t *testing.T) {
			if _, err := processLockPath(dir, port); err == nil {
				t.Fatalf("非法端口 %q 未被拒绝", port)
			}
		})
	}
}

func TestProcessLockExclusiveAndRelease(t *testing.T) {
	dir := t.TempDir()
	path, err := processLockPath(dir, "8000")
	if err != nil {
		t.Fatal(err)
	}
	content := []byte("已有文件内容不可被截断")
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}

	lock, err := acquireProcessLock(dir, "8000")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lock.Close() })

	flags, _, errno := syscall.Syscall(syscall.SYS_FCNTL, lock.Fd(), syscall.F_GETFD, 0)
	if errno != 0 {
		t.Fatal(errno)
	}
	if flags&syscall.FD_CLOEXEC == 0 {
		t.Fatal("进程锁文件描述符没有设置 close-on-exec")
	}
	if duplicate, err := acquireProcessLock(dir, "8000"); err == nil {
		_ = duplicate.Close()
		t.Fatal("同一锁被第二次成功获取")
	} else if !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("重复加锁错误 = %v，期望 EWOULDBLOCK", err)
	}

	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := acquireProcessLock(dir, "8000")
	if err != nil {
		t.Fatalf("关闭后无法重新加锁: %v", err)
	}
	if err := reopened.Close(); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatalf("锁文件没有保留: %v", err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("锁文件被替换")
	}
	actual, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, content) {
		t.Fatalf("锁文件内容改变: %q", actual)
	}
}

func TestProcessLockPortIsolation(t *testing.T) {
	dir := t.TempDir()
	for _, port := range []string{"8000", "8001"} {
		lock, err := acquireProcessLock(dir, port)
		if err != nil {
			t.Fatalf("端口 %s 无法独立加锁: %v", port, err)
		}
		t.Cleanup(func() { _ = lock.Close() })
	}
}

func TestProcessLockOpenErrors(t *testing.T) {
	t.Run("missing directory", func(t *testing.T) {
		lock, err := acquireProcessLock(filepath.Join(t.TempDir(), "missing"), "8000")
		if lock != nil {
			_ = lock.Close()
			t.Fatal("打开失败时返回了文件")
		}
		if !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("打开错误 = %v，期望文件不存在", err)
		}
	})
	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		path, err := processLockPath(dir, "8000")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(dir, "target"), path); err != nil {
			t.Fatal(err)
		}
		if lock, err := acquireProcessLock(dir, "8000"); err == nil {
			_ = lock.Close()
			t.Fatal("不应跟随锁文件符号链接")
		}
	})
	t.Run("not regular file", func(t *testing.T) {
		dir := t.TempDir()
		path, err := processLockPath(dir, "8000")
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Mkfifo(path, 0600); err != nil {
			t.Fatal(err)
		}
		if lock, err := acquireProcessLock(dir, "8000"); err == nil {
			_ = lock.Close()
			t.Fatal("不应在非普通文件上持锁")
		}
	})
}

func TestProcessLockReleasedAfterSIGKILL(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestProcessLockHelper$")
	cmd.Env = append(os.Environ(), "BILIPOCKET_LOCK_TEST_DIR="+dir)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	waited := false
	t.Cleanup(func() {
		_ = stdin.Close()
		if !waited {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})

	if line, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("辅助进程未就绪: %q，%v", line, err)
	}
	if lock, err := acquireProcessLock(dir, "8000"); err == nil {
		_ = lock.Close()
		t.Fatal("辅助进程运行时锁未被占用")
	} else if !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("检查辅助进程锁失败: %v", err)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	waitErr := cmd.Wait()
	waited = true
	var exitErr *exec.ExitError
	if !errors.As(waitErr, &exitErr) || exitErr.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		t.Fatalf("辅助进程未因 SIGKILL 结束: %v，stderr=%s", waitErr, stderr.String())
	}

	path, err := processLockPath(dir, "8000")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("SIGKILL 后锁文件应保留: %v", err)
	}
	lock, err := acquireProcessLock(dir, "8000")
	if err != nil {
		t.Fatalf("SIGKILL 后锁未释放: %v", err)
	}
	_ = lock.Close()
}

func TestProcessLockHelper(t *testing.T) {
	dir := os.Getenv("BILIPOCKET_LOCK_TEST_DIR")
	if dir == "" {
		t.Skip("仅供进程锁测试启动的辅助进程使用")
	}
	lock, err := acquireProcessLock(dir, "8000")
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
}
