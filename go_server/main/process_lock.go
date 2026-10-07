package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

func processLockPath(dir, port string) (string, error) {
	portNumber, err := strconv.ParseUint(port, 10, 16)
	if err != nil || portNumber == 0 {
		return "", fmt.Errorf("无效的监听端口 %q", port)
	}
	return filepath.Join(dir, fmt.Sprintf("bilipocket-server-%d.lock", portNumber)), nil
}

// 返回的文件须持有到进程结束；不删除锁文件，避免检测方锁到不同的文件对象。
func acquireProcessLock(dir, port string) (*os.File, error) {
	path, err := processLockPath(dir, port)
	if err != nil {
		return nil, err
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, fmt.Errorf("打开进程锁 %s 失败: %w", path, err)
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = file.Close()
		if err != nil {
			return nil, fmt.Errorf("检查进程锁 %s 失败: %w", path, err)
		}
		return nil, fmt.Errorf("进程锁 %s 不是普通文件", path)
	}

	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("获取进程锁 %s 失败: %w", path, err)
	}
	return file, nil
}
