package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Each connection has a byte-idle deadline, never a total download deadline.
// Four HTTP ranges run concurrently; WriteAt avoids buffering entire segments.
type mediaDownloader struct {
	client            *http.Client
	idle              time.Duration
	parallelThreshold int64
}

func newMediaDownloader() *mediaDownloader {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxConnsPerHost = 4
	transport.MaxIdleConnsPerHost = 4
	transport.DisableCompression = true
	return &mediaDownloader{client: &http.Client{Transport: transport}, idle: 30 * time.Second, parallelThreshold: 4 << 20}
}

type idleBody struct {
	io.ReadCloser
	timer  *time.Timer
	cancel context.CancelFunc
	idle   time.Duration
}

func (b *idleBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if n > 0 {
		b.timer.Reset(b.idle)
	}
	return n, err
}
func (b *idleBody) Close() error { b.timer.Stop(); b.cancel(); return b.ReadCloser.Close() }

func (d *mediaDownloader) request(ctx context.Context, url, byteRange, validator string) (*http.Response, error) {
	ctx, cancel := context.WithCancel(ctx)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Referer", "https://www.bilibili.com/")
	req.Header.Set("Accept-Encoding", "identity")
	if byteRange != "" {
		req.Header.Set("Range", byteRange)
	}
	if validator != "" {
		req.Header.Set("If-Range", validator)
	}
	timer := time.AfterFunc(d.idle, cancel)
	resp, err := d.client.Do(req)
	if err != nil {
		timer.Stop()
		cancel()
		return nil, err
	}
	resp.Body = &idleBody{ReadCloser: resp.Body, timer: timer, cancel: cancel, idle: d.idle}
	return resp, nil
}

type downloadRange struct{ Start, End, Done int64 }
type rangeCheckpoint struct {
	Identity  string
	Size      int64
	Validator string
	Ranges    []downloadRange
}

func atomicJSON(path string, value interface{}) error {
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(path+".tmp", path)
	}
	if err == nil {
		dir, openErr := os.Open(filepath.Dir(path))
		if openErr != nil {
			return openErr
		}
		err = dir.Sync()
		dir.Close()
	}
	if err != nil {
		_ = os.Remove(path + ".tmp")
	}
	return err
}

func parseContentRange(s string) (start, end, total int64, ok bool) {
	_, err := fmt.Sscanf(s, "bytes %d-%d/%d", &start, &end, &total)
	return start, end, total, err == nil && start >= 0 && end >= start && total > end
}

var errRangeIgnored = errors.New("服务器不支持分段请求")

func (d *mediaDownloader) download(ctx context.Context, url, path, identity string, progress func(int64, int64)) error {
	probe, err := d.request(ctx, url, "bytes=0-0", "")
	if err != nil {
		return err
	}
	start, end, total, ranged := parseContentRange(probe.Header.Get("Content-Range"))
	ranged = ranged && probe.StatusCode == http.StatusPartialContent && start == 0 && end == 0
	validator := probe.Header.Get("ETag")
	if strings.HasPrefix(validator, "W/") {
		validator = ""
	}
	if validator == "" {
		validator = probe.Header.Get("Last-Modified")
	}
	status := probe.StatusCode
	probe.Body.Close()
	if status != http.StatusOK && status != http.StatusPartialContent {
		return fmt.Errorf("媒体地址返回 HTTP %d", status)
	}
	if !ranged {
		return d.single(ctx, url, path, progress)
	}
	err = d.ranges(ctx, url, path, identity, validator, total, progress)
	if errors.Is(err, errRangeIgnored) && ctx.Err() == nil {
		return d.single(ctx, url, path, progress)
	}
	return err
}

func (d *mediaDownloader) ranges(ctx context.Context, url, path, identity, validator string, total int64, progress func(int64, int64)) error {
	checkpoint := rangeCheckpoint{Identity: identity, Size: total, Validator: validator}
	var old rangeCheckpoint
	b, readErr := os.ReadFile(path + ".json")
	valid := readErr == nil && json.Unmarshal(b, &old) == nil && old.Identity == identity && old.Size == total && old.Validator == validator && len(old.Ranges) > 0 && len(old.Ranges) <= 4
	var next int64
	fi, statErr := os.Stat(path)
	for _, r := range old.Ranges {
		if r.Start != next || r.End < r.Start || r.End >= total || r.Done < 0 || r.Done > r.End-r.Start+1 || (r.Done > 0 && (statErr != nil || fi.Size() < r.Start+r.Done)) {
			valid = false
		}
		next = r.End + 1
	}
	valid = valid && next == total
	if valid {
		checkpoint = old
	} else {
		_ = os.Remove(path + ".json")
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		count := int64(1)
		if total >= d.parallelThreshold {
			count = 4
		}
		for i := int64(0); i < count; i++ {
			checkpoint.Ranges = append(checkpoint.Ranges, downloadRange{Start: total * i / count, End: total*(i+1)/count - 1})
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	var mu sync.Mutex
	var received int64
	for _, r := range checkpoint.Ranges {
		received += r.Done
	}
	progress(received, total)
	save := func() error {
		mu.Lock()
		defer mu.Unlock()
		if err := f.Sync(); err != nil {
			return err
		}
		return atomicJSON(path+".json", checkpoint)
	}
	if err := save(); err != nil {
		return err
	}
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	var firstErr error
	reportError := func(err error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
		cancel()
	}
	for i, r := range checkpoint.Ranges {
		if r.Done == r.End-r.Start+1 {
			continue
		}
		wg.Add(1)
		go func(i int, r downloadRange) {
			defer wg.Done()
			offset := r.Start + r.Done
			resp, err := d.request(child, url, fmt.Sprintf("bytes=%d-%d", offset, r.End), validator)
			if err != nil {
				reportError(err)
				return
			}
			defer resp.Body.Close()
			start, end, size, ok := parseContentRange(resp.Header.Get("Content-Range"))
			if resp.StatusCode == http.StatusOK {
				reportError(errRangeIgnored)
				return
			}
			if resp.StatusCode != http.StatusPartialContent || !ok || start != offset || end != r.End || size != total {
				reportError(fmt.Errorf("分段响应无效 (HTTP %d)", resp.StatusCode))
				return
			}
			buf := make([]byte, 128<<10)
			for {
				n, readErr := resp.Body.Read(buf)
				if n > 0 {
					if offset+int64(n) > r.End+1 {
						reportError(errors.New("分段数据超过声明长度"))
						return
					}
					written, err := f.WriteAt(buf[:n], offset)
					if err != nil || written != n {
						if err == nil {
							err = io.ErrShortWrite
						}
						reportError(err)
						return
					}
					offset += int64(n)
					mu.Lock()
					checkpoint.Ranges[i].Done += int64(n)
					received += int64(n)
					progress(received, total)
					mu.Unlock()
				}
				if readErr != nil {
					if readErr != io.EOF {
						reportError(readErr)
					} else if offset != r.End+1 {
						reportError(io.ErrUnexpectedEOF)
					}
					return
				}
			}
		}(i, r)
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if err := save(); err != nil {
				reportError(err)
			}
		case <-done:
			if err := save(); err != nil {
				return err
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return firstErr
		}
	}
}

// Servers ignoring Range remain usable, but cannot safely resume partial bytes.
func (d *mediaDownloader) single(ctx context.Context, url, path string, progress func(int64, int64)) error {
	_ = os.Remove(path + ".json")
	resp, err := d.request(ctx, url, "", "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("下载返回 HTTP %d", resp.StatusCode)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	total, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64)
	var received int64
	progress(0, total)
	buf := make([]byte, 128<<10)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			written, err := f.Write(buf[:n])
			if err != nil {
				return err
			}
			if written != n {
				return io.ErrShortWrite
			}
			received += int64(n)
			progress(received, total)
		}
		if readErr != nil {
			if readErr != io.EOF {
				return readErr
			}
			if total > 0 && received != total {
				return io.ErrUnexpectedEOF
			}
			return f.Sync()
		}
	}
}
