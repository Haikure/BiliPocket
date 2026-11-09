package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type downloadTask struct {
	ID              string  `json:"id"`
	Bvid            string  `json:"bvid"`
	Aid             int     `json:"aid"`
	Cid             int     `json:"cid"`
	Title           string  `json:"title"`
	Cover           string  `json:"cover"`
	Quality         int     `json:"quality"`
	ActualQuality   int     `json:"actualQuality"`
	PreferMP4       bool    `json:"preferMp4"`
	Subtitle        string  `json:"subtitle"`
	DefaultSubtitle bool    `json:"defaultSubtitle"`
	Kind            string  `json:"kind"`
	State           string  `json:"state"`
	Status          string  `json:"status"`
	Progress        float64 `json:"progress"`
	Received        int64   `json:"received"`
	Total           int64   `json:"total"`
	Speed           int64   `json:"speed"`
	Output          string  `json:"output"`
	Paused          bool    `json:"paused"`
	RunWhilePaused  bool    `json:"runWhilePaused"`
}

type downloadQueueDisk struct {
	Paused bool            `json:"paused"`
	Tasks  []*downloadTask `json:"tasks"`
	Error  string          `json:"error,omitempty"`
}

type downloadQueue struct {
	mu           sync.Mutex
	disk         downloadQueueDisk
	root, output string
	active       string
	cancel       context.CancelFunc
	wake         chan struct{}
	ctx          context.Context
	stop         context.CancelFunc
	done         chan struct{}
	downloader   *mediaDownloader
	storageError error
}

var downloads *downloadQueue

func newDownloadQueue(root, output string) *downloadQueue {
	ctx, stop := context.WithCancel(context.Background())
	q := &downloadQueue{root: root, output: output, ctx: ctx, stop: stop, done: make(chan struct{}), wake: make(chan struct{}, 1), downloader: newMediaDownloader()}
	q.storageError = os.MkdirAll(root, 0700)
	if q.storageError == nil {
		if b, err := os.ReadFile(filepath.Join(root, "queue.json")); err == nil {
			if err := json.Unmarshal(b, &q.disk); err != nil {
				// Preserve damaged metadata and its partials for recovery, never silently purge them.
				q.storageError = fmt.Errorf("缓存索引损坏: %w", err)
			}
		} else if !os.IsNotExist(err) {
			q.storageError = err
		}
	}
	if q.storageError == nil {
		keep := map[string]bool{}
		var tasks []*downloadTask
		removed := false
		for _, t := range q.disk.Tasks {
			if t == nil || !validTaskID(t.ID) || keep[t.ID] {
				continue
			}
			keep[t.ID] = true
			if t.State == "deleting" {
				_ = os.RemoveAll(q.taskDir(t.ID))
				removed = removed || t.Output == ""
				continue
			}
			if t.State != "complete" && t.State != "error" {
				q.setWaitingState(t)
			}
			tasks = append(tasks, t)
			if t.State == "complete" {
				_ = os.RemoveAll(q.taskDir(t.ID))
			}
		}
		q.disk.Tasks = tasks
		if removed {
			q.resetPauseAfterRemoval()
		}
		entries, _ := os.ReadDir(root)
		for _, entry := range entries {
			if entry.IsDir() && validTaskID(entry.Name()) && !keep[entry.Name()] {
				_ = os.RemoveAll(filepath.Join(root, entry.Name()))
			}
		}
		q.storageError = q.saveLocked()
	}
	go q.run()
	q.notify()
	return q
}

func validTaskID(id string) bool                  { b, err := hex.DecodeString(id); return err == nil && len(b) == 16 }
func (q *downloadQueue) taskDir(id string) string { return filepath.Join(q.root, id) }
func (q *downloadQueue) saveLocked() error {
	return atomicJSON(filepath.Join(q.root, "queue.json"), q.disk)
}
func (q *downloadQueue) notify() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}
func (q *downloadQueue) close() { q.stop(); <-q.done }

func (q *downloadQueue) snapshot() downloadQueueDisk {
	q.mu.Lock()
	defer q.mu.Unlock()
	s := downloadQueueDisk{Paused: q.disk.Paused, Tasks: make([]*downloadTask, 0, len(q.disk.Tasks))}
	if q.storageError != nil {
		s.Error = q.storageError.Error()
		s.Paused = true
	}
	for _, t := range q.disk.Tasks {
		copy := *t
		s.Tasks = append(s.Tasks, &copy)
	}
	return s
}

func (q *downloadQueue) enqueue(t downloadTask) error {
	if t.Aid <= 0 || t.Cid <= 0 || t.Bvid == "" || len(t.Title) > 2000 || len(t.Cover) > 4096 {
		return errors.New("视频信息不完整")
	}
	switch t.Quality {
	case 0, 16, 32, 64, 80, 112, 116, 120, 125:
	default:
		return errors.New("不支持的清晰度")
	}
	if t.Subtitle != "" {
		u, err := url.Parse(t.Subtitle)
		if err != nil || u.Path != "/video/subtitle/ass/file" {
			return errors.New("字幕参数无效")
		}
		// Store only local endpoint parameters, never a caller-supplied host.
		u.Scheme = ""
		u.Host = ""
		t.Subtitle = u.String()
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", t.Bvid, t.Cid, t.Quality)))
	t.ID = hex.EncodeToString(sum[:16])
	t.State = "queued"
	t.Status = "等待下载"
	t.Progress = 0
	t.Output = ""
	t.Speed = 0
	t.Received = 0
	t.Total = 0
	t.Paused = false
	t.RunWhilePaused = false
	t.Kind = "DASH"
	if t.PreferMP4 {
		t.Kind = "MP4"
	}
	if t.Quality == 0 {
		t.Kind = "音频"
	}
	t.ActualQuality = t.Quality
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.storageError != nil {
		return q.storageError
	}
	for _, old := range q.disk.Tasks {
		if old.ID == t.ID {
			return errors.New("该视频已在缓存列表中")
		}
	}
	// Removing a completed queue entry does not remove its public media file.
	if exists, err := q.hasPublishedDownload(t); err != nil {
		return err
	} else if exists {
		return errors.New("该视频已下载，文件在 bili 文件夹中")
	}
	q.setWaitingState(&t)
	q.disk.Tasks = append(q.disk.Tasks, &t)
	if err := q.saveLocked(); err != nil {
		q.disk.Tasks = q.disk.Tasks[:len(q.disk.Tasks)-1]
		return err
	}
	q.notify()
	return nil
}

func (q *downloadQueue) hasPublishedDownload(t downloadTask) (bool, error) {
	entries, err := os.ReadDir(q.output)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("无法检查已下载文件: %w", err)
	}
	ext := ".mp4"
	if t.Quality == 0 {
		ext = ".m4a"
	}
	suffix := "_" + t.ID[:12] + ext
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), suffix) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return false, err
		}
		if info.Mode().IsRegular() && info.Size() > 0 {
			return true, nil
		}
	}
	return false, nil
}

// Called with the queue lock held (or during initial load before the worker).
func (q *downloadQueue) taskPaused(t *downloadTask) bool {
	return t.Paused || (q.disk.Paused && !t.RunWhilePaused)
}

func (q *downloadQueue) setWaitingState(t *downloadTask) {
	t.Speed = 0
	if q.taskPaused(t) {
		t.State = "paused"
		t.Status = "已暂停 · 点击继续"
	} else {
		t.State = "queued"
		t.Status = "等待下载 · 点击暂停"
	}
}

// Deleting the last unfinished item ends the old paused batch. A subsequent
// explicit Pause All on an empty queue still holds newly added downloads.
func (q *downloadQueue) resetPauseAfterRemoval() {
	for _, t := range q.disk.Tasks {
		if t.State != "complete" {
			return
		}
	}
	q.disk.Paused = false
}

func (q *downloadQueue) control(action, id string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.storageError != nil {
		return q.storageError
	}
	switch action {
	case "clear_completed":
		previous := q.disk.Tasks
		keep := make([]*downloadTask, 0, len(previous))
		for _, t := range previous {
			if t.State != "complete" {
				keep = append(keep, t)
				continue
			}
			// Public media and subtitles belong to the user; only remove the
			// completed queue record and any private download leftovers.
			if err := os.RemoveAll(q.taskDir(t.ID)); err != nil {
				return fmt.Errorf("清理缓存失败: %w", err)
			}
		}
		if len(keep) == len(previous) {
			return nil
		}
		q.disk.Tasks = keep
		if err := q.saveLocked(); err != nil {
			q.disk.Tasks = previous
			return err
		}
	case "pause", "start":
		old := q.disk.Paused
		q.disk.Paused = action == "pause"
		previous := make([]downloadTask, len(q.disk.Tasks))
		for i, t := range q.disk.Tasks {
			previous[i] = *t
			if t.State == "complete" || t.State == "deleting" {
				continue
			}
			t.Paused = q.disk.Paused
			t.RunWhilePaused = false
			if q.active != t.ID || q.disk.Paused || t.State == "paused" {
				q.setWaitingState(t)
			}
		}
		if err := q.saveLocked(); err != nil {
			q.disk.Paused = old
			for i, t := range q.disk.Tasks {
				*t = previous[i]
			}
			return err
		}
		if q.disk.Paused && q.cancel != nil {
			q.cancel()
		}
	case "pause_task", "resume_task":
		var task *downloadTask
		for _, t := range q.disk.Tasks {
			if t.ID == id {
				task = t
				break
			}
		}
		if task == nil {
			return errors.New("缓存任务已移除")
		}
		if task.State == "complete" || task.State == "deleting" {
			return nil
		}
		pause := action == "pause_task"
		if !pause && !q.taskPaused(task) && task.State != "error" {
			return nil
		}
		previous := *task
		task.Paused = pause
		task.RunWhilePaused = !pause && q.disk.Paused
		q.setWaitingState(task)
		if err := q.saveLocked(); err != nil {
			*task = previous
			return err
		}
		if pause && q.active == id && q.cancel != nil {
			q.cancel()
		}
	case "remove":
		for i, t := range q.disk.Tasks {
			if t.ID != id {
				continue
			}
			old := t.State
			t.State = "deleting"
			if err := q.saveLocked(); err != nil {
				t.State = old
				return err
			}
			if q.active == id {
				q.cancel()
				break
			}
			if err := os.RemoveAll(q.taskDir(id)); err != nil {
				return err
			}
			q.disk.Tasks = append(q.disk.Tasks[:i], q.disk.Tasks[i+1:]...)
			if old != "complete" {
				q.resetPauseAfterRemoval()
			}
			return q.saveLocked()
		}
	default:
		return errors.New("未知队列操作")
	}
	q.notify()
	return nil
}

func (q *downloadQueue) update(id, state, status string, progress float64, received, total, speed int64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, t := range q.disk.Tasks {
		if t.ID == id && t.State != "deleting" && !q.taskPaused(t) {
			t.State = state
			t.Status = status
			t.Progress = progress
			t.Received = received
			t.Total = total
			t.Speed = speed
			return
		}
	}
}

func (q *downloadQueue) run() {
	defer close(q.done)
	for {
		select {
		case <-q.ctx.Done():
			return
		case <-q.wake:
		}
		for q.ctx.Err() == nil {
			q.mu.Lock()
			var task *downloadTask
			if q.storageError == nil {
				for _, t := range q.disk.Tasks {
					if t.State == "queued" && !q.taskPaused(t) {
						copy := *t
						task = &copy
						break
					}
				}
			}
			if task == nil {
				q.mu.Unlock()
				break
			}
			ctx, cancel := context.WithCancel(q.ctx)
			q.cancel = cancel
			q.active = task.ID
			q.mu.Unlock()
			err := q.executeSafely(ctx, task)
			cancel()
			q.mu.Lock()
			for i, t := range q.disk.Tasks {
				if t.ID != task.ID {
					continue
				}
				if t.State == "deleting" {
					if cleanupErr := os.RemoveAll(q.taskDir(t.ID)); cleanupErr != nil {
						t.State = "error"
						t.Status = "清理失败: " + cleanupErr.Error()
					} else {
						q.disk.Tasks = append(q.disk.Tasks[:i], q.disk.Tasks[i+1:]...)
						q.resetPauseAfterRemoval()
					}
				} else if err == nil {
					t.State = "complete"
					t.Status = task.Status
					t.Progress = 1
					t.Output = task.Output
					t.Paused = false
					t.RunWhilePaused = false
				} else if errors.Is(err, context.Canceled) || q.taskPaused(t) {
					// A quick resume may arrive while the cancelled request unwinds.
					// Settle according to the latest intent, never the old callback.
					q.setWaitingState(t)
				} else {
					t.State = "error"
					t.Status = "下载失败: " + err.Error()
				}
				t.Speed = 0
				break
			}
			q.active = ""
			q.cancel = nil
			if err := q.saveLocked(); err != nil {
				q.storageError = err
				q.disk.Paused = true
			} else {
				for _, t := range q.disk.Tasks {
					if t.ID == task.ID && t.State == "complete" {
						_ = os.RemoveAll(q.taskDir(t.ID))
					}
				}
			}
			q.mu.Unlock()
		}
	}
}

type playStream struct {
	ID           int    `json:"id"`
	Codecs       string `json:"codecs"`
	BaseURL      string `json:"base_url"`
	BaseURLCamel string `json:"baseUrl"`
}

func (s playStream) url() string {
	if s.BaseURL != "" {
		return s.BaseURL
	}
	return s.BaseURLCamel
}

type downloadPlayData struct {
	Quality int `json:"quality"`
	Durl    []struct {
		URL    string   `json:"url"`
		Backup []string `json:"backup_url"`
	} `json:"durl"`
	Dash struct{ Video, Audio []playStream } `json:"dash"`
}

func fetchDownloadStreams(ctx context.Context, t *downloadTask, fnval int) (downloadPlayData, error) {
	qn := t.Quality
	if qn == 0 {
		qn = 16
	}
	b, err := getClient().GetPlayUrl(ctx, t.Aid, t.Cid, qn, fnval, "pc")
	var resp struct {
		Code    int              `json:"code"`
		Message string           `json:"message"`
		Data    downloadPlayData `json:"data"`
	}
	if err == nil {
		err = json.Unmarshal(b, &resp)
	}
	if err == nil && resp.Code != 0 {
		err = fmt.Errorf("获取地址失败: %s (%d)", resp.Message, resp.Code)
	}
	return resp.Data, err
}

func chooseStream(streams []playStream, qn int) playStream {
	var chosen playStream
	for _, s := range streams {
		if s.url() == "" {
			continue
		}
		if chosen.url() == "" || (s.ID == qn && chosen.ID != qn) ||
			(chosen.ID != qn && s.ID <= qn && (chosen.ID > qn || s.ID > chosen.ID)) ||
			(chosen.ID > qn && s.ID < chosen.ID) ||
			(s.ID == chosen.ID && strings.HasPrefix(s.Codecs, "avc") && !strings.HasPrefix(chosen.Codecs, "avc")) {
			chosen = s
		}
	}
	return chosen
}

func (q *downloadQueue) transfer(ctx context.Context, t *downloadTask, streamURL, name, identity, label string) error {
	path := filepath.Join(q.taskDir(t.ID), name)
	var done struct {
		Identity string
		Size     int64
	}
	if b, err := os.ReadFile(path + ".done"); err == nil && json.Unmarshal(b, &done) == nil && done.Identity == identity {
		if fi, err := os.Stat(path); err == nil && fi.Size() == done.Size && fi.Size() > 0 {
			return nil
		}
	}
	var progressMu sync.Mutex
	var received, total, speed int64
	var meter downloadSpeedMeter
	initialized := false
	updateProgress := func() {
		p := float64(0)
		if total > 0 {
			p = float64(received) / float64(total)
		}
		q.update(t.ID, "downloading", label, p, received, total, speed)
	}
	stopProgress := make(chan struct{})
	progressDone := make(chan struct{})
	go func() {
		defer close(progressDone)
		ticker := time.NewTicker(downloadSpeedInterval)
		defer ticker.Stop()
		for {
			select {
			case <-stopProgress:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				progressMu.Lock()
				if initialized {
					speed = meter.sample(time.Now(), received)
					updateProgress()
				}
				progressMu.Unlock()
			}
		}
	}()
	defer func() { close(stopProgress); <-progressDone }()
	err := q.downloader.download(ctx, streamURL, path, identity, func(bytes, size int64) {
		progressMu.Lock()
		defer progressMu.Unlock()
		if !initialized || bytes < received {
			// A server ignoring Range restarts the file and the measurement window.
			meter.reset(time.Now(), bytes)
			initialized = true
			speed = 0
		}
		received, total = bytes, size
		updateProgress()
	})
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%s（30 秒无数据会中止，可继续）: %w", label, err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		return err
	}
	if fi.Size() == 0 {
		return errors.New("下载文件为空")
	}
	done.Identity = identity
	done.Size = fi.Size()
	return atomicJSON(path+".done", done)
}

func (q *downloadQueue) executeSafely(ctx context.Context, t *downloadTask) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("处理媒体失败: %v", recovered)
		}
		if err != nil {
			_ = os.Remove(filepath.Join(q.taskDir(t.ID), "result.mp4.part"))
		}
	}()
	return q.execute(ctx, t)
}

func (q *downloadQueue) execute(ctx context.Context, t *downloadTask) error {
	dir := q.taskDir(t.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	// Publication is journaled before touching the public directory. A crash
	// after publishing resumes here, without re-merging an already linked file.
	var publication downloadPublication
	if b, err := os.ReadFile(filepath.Join(dir, "publish.json")); err == nil {
		if json.Unmarshal(b, &publication) != nil {
			return errors.New("保存记录损坏")
		}
		return q.finishPublication(ctx, t, publication)
	}
	// Refreshing signed URLs must keep the saved progress until the media
	// transfer reports its checkpoint (or starts the next DASH stream).
	q.update(t.ID, "resolving", "获取下载地址", t.Progress, t.Received, t.Total, 0)
	fnval := 4048
	if t.PreferMP4 && t.Quality != 0 {
		fnval = 1
	}
	data, err := fetchDownloadStreams(ctx, t, fnval)
	if err != nil {
		return err
	}
	mp4URL := ""
	if fnval == 1 && len(data.Durl) == 1 && (data.Quality == 0 || data.Quality >= t.Quality) {
		mp4URL = data.Durl[0].URL
		if mp4URL == "" && len(data.Durl[0].Backup) > 0 {
			mp4URL = data.Durl[0].Backup[0]
		}
	}
	if fnval == 1 && mp4URL == "" {
		data, err = fetchDownloadStreams(ctx, t, 4048)
		if err != nil {
			return err
		}
	}
	video := chooseStream(data.Dash.Video, t.Quality)
	audio := chooseStream(data.Dash.Audio, 30280)
	output := filepath.Join(dir, "result.mp4")
	if t.Quality == 0 {
		t.Kind = "音频"
		t.ActualQuality = 0
		output = filepath.Join(dir, "audio.m4a")
	} else if mp4URL != "" {
		t.Kind = "MP4"
		t.ActualQuality = data.Quality
	} else {
		t.Kind = "DASH"
		t.ActualQuality = video.ID
	}
	q.mu.Lock()
	for _, live := range q.disk.Tasks {
		if live.ID == t.ID {
			live.Kind = t.Kind
			live.ActualQuality = t.ActualQuality
		}
	}
	q.mu.Unlock()
	if t.Kind == "MP4" {
		err = q.transfer(ctx, t, mp4URL, "result.mp4", fmt.Sprintf("mp4:%d", t.ActualQuality), "下载视频")
	} else if t.Kind == "音频" {
		if audio.url() == "" {
			return errors.New("未获取到音频流")
		}
		err = q.transfer(ctx, t, audio.url(), "audio.m4a", fmt.Sprintf("audio:%d:%s", audio.ID, audio.Codecs), "下载音频")
	} else {
		if video.url() == "" || audio.url() == "" {
			return errors.New("未获取到完整音视频流")
		}
		err = q.transfer(ctx, t, video.url(), "video.m4s", fmt.Sprintf("video:%d:%s", video.ID, video.Codecs), "下载视频 1/2")
		if err == nil {
			err = q.transfer(ctx, t, audio.url(), "audio.m4s", fmt.Sprintf("audio:%d:%s", audio.ID, audio.Codecs), "下载音频 2/2")
		}
		if err == nil {
			q.update(t.ID, "merging", "正在合并", 0, 0, 0, 0)
			v, statErr := os.Stat(filepath.Join(dir, "video.m4s"))
			if statErr != nil {
				return statErr
			}
			a, statErr := os.Stat(filepath.Join(dir, "audio.m4s"))
			if statErr != nil {
				return statErr
			}
			free, spaceErr := diskFreeBytes(dir)
			if spaceErr != nil {
				return spaceErr
			}
			if free < uint64(v.Size()+a.Size())+(16<<20) {
				return errors.New("空间不足，已保留断点")
			}
			err = mergeM4s(ctx, filepath.Join(dir, "video.m4s"), filepath.Join(dir, "audio.m4s"), output+".part")
			if err == nil {
				err = os.Rename(output+".part", output)
			} else {
				_ = os.Remove(output + ".part")
			}
		}
	}
	if err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	t.Status = "已完成"
	if t.Subtitle == "" && t.DefaultSubtitle {
		subs, subErr := fetchPlayerSubtitleList(ctx, getClient(), t.Aid, t.Cid, t.Bvid)
		if subErr != nil {
			t.Status = "已完成 · 字幕获取失败"
		} else {
			for _, sub := range subs {
				obj, ok := sub.(map[string]interface{})
				if !ok {
					continue
				}
				lan := strings.ToLower(fmt.Sprint(obj["lan"]) + fmt.Sprint(obj["lan_doc"]))
				if !strings.Contains(lan, "zh") && !strings.Contains(lan, "中文") && !strings.Contains(lan, "chinese") {
					continue
				}
				sid := ""
				for _, key := range []string{"id_str", "id", "subtitle_id"} {
					switch v := obj[key].(type) {
					case string:
						sid = v
					case float64:
						sid = strconv.FormatInt(int64(v), 10)
					}
					if sid != "" {
						break
					}
				}
				if sid != "" {
					t.Subtitle = fmt.Sprintf("/video/subtitle/ass/file?aid=%d&cid=%d&sid=%s&bvid=%s", t.Aid, t.Cid, url.QueryEscape(sid), url.QueryEscape(t.Bvid))
					break
				}
			}
		}
	}
	if t.Subtitle != "" {
		q.update(t.ID, "subtitle", "保存字幕", 0, 0, 0, 0)
		err = saveDownloadSubtitle(ctx, t, filepath.Join(dir, "subtitle.ass"))
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			t.Status = "已完成 · 字幕保存失败"
		}
	}
	q.update(t.ID, "saving", "保存文件", 0, 0, 0, 0)
	if err := os.MkdirAll(q.output, 0755); err != nil {
		return err
	}
	title := strings.Map(func(r rune) rune {
		if r < 32 || strings.ContainsRune("/\\:*?\"<>|", r) {
			return -1
		}
		return r
	}, t.Title)
	runes := []rune(strings.TrimSpace(title))
	if len(runes) > 60 {
		runes = runes[:60]
	}
	title = string(runes)
	if title == "" {
		title = t.Bvid
	}
	ext := ".mp4"
	if t.Quality == 0 {
		ext = ".m4a"
	}
	t.Output = filepath.Join(q.output, fmt.Sprintf("%s_%s%s", title, t.ID[:12], ext))
	info, err := os.Stat(output)
	if err != nil {
		return err
	}
	publication = downloadPublication{Source: filepath.Base(output), Destination: filepath.Base(t.Output), Status: t.Status, Size: info.Size()}
	if err := atomicJSON(filepath.Join(dir, "publish.json"), publication); err != nil {
		return err
	}
	return q.finishPublication(ctx, t, publication)
}

func saveDownloadSubtitle(ctx context.Context, t *downloadTask, path string) error {
	u, err := url.Parse(t.Subtitle)
	if err != nil {
		return err
	}
	params := u.Query()
	sid, err := strconv.Atoi(params.Get("sid"))
	if err != nil {
		return err
	}
	subs, err := fetchPlayerSubtitleList(ctx, getClient(), t.Aid, t.Cid, t.Bvid)
	if err != nil {
		return err
	}
	subURL := getSubtitleURL(subs, sid)
	if subURL == "" {
		return errors.New("字幕不可用")
	}
	body, err := fetchSubtitleBody(ctx, getClient(), subURL)
	if err != nil {
		return err
	}
	// This writer only captures validation errors from the shared style parser.
	validation := &subtitleValidationWriter{}
	font, margin, spacing, weight, color, outline, outlineWidth, background, opacity, ok := subtitleStyleParamsFromRequest(validation, params)
	if !ok {
		return errors.New("字幕样式参数无效")
	}
	content := buildASSFromSubtitleBody(body, font, margin, spacing, weight, color, outline, outlineWidth, background, opacity)
	return os.WriteFile(path, []byte(content), 0600)
}

type subtitleValidationWriter struct{}

func (*subtitleValidationWriter) Header() http.Header         { return make(http.Header) }
func (*subtitleValidationWriter) WriteHeader(int)             {}
func (*subtitleValidationWriter) Write(p []byte) (int, error) { return len(p), nil }

type downloadPublication struct {
	Source, Destination, Status string
	Size                        int64
}

func (q *downloadQueue) finishPublication(ctx context.Context, t *downloadTask, p downloadPublication) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if p.Source != filepath.Base(p.Source) || p.Destination != filepath.Base(p.Destination) || p.Source == "." || p.Destination == "." {
		return errors.New("保存路径无效")
	}
	if err := os.MkdirAll(q.output, 0755); err != nil {
		return err
	}
	t.Output = filepath.Join(q.output, p.Destination)
	t.Status = p.Status
	source := filepath.Join(q.taskDir(t.ID), p.Source)
	if _, err := os.Stat(source); os.IsNotExist(err) {
		// Filesystems without hard links use an atomic rename. The private journal
		// identifies the published file if power was lost before queue completion.
		info, err := os.Stat(t.Output)
		if err != nil || info.Size() != p.Size || p.Size <= 0 {
			return errors.New("已保存文件缺失或不完整")
		}
	} else if err := publishDownload(source, t.Output); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(q.taskDir(t.ID), "subtitle.ass")); err == nil {
		if err := publishDownload(filepath.Join(q.taskDir(t.ID), "subtitle.ass"), strings.TrimSuffix(t.Output, filepath.Ext(t.Output))+".ass"); err != nil {
			t.Status = "已完成 · 字幕保存失败"
		}
	}
	return nil
}

func publishDownload(source, dest string) error {
	if err := os.Link(source, dest); err != nil {
		src, srcErr := os.Stat(source)
		dst, dstErr := os.Stat(dest)
		if srcErr == nil && dstErr == nil && os.SameFile(src, dst) {
			return nil
		}
		if srcErr == nil && os.IsNotExist(dstErr) && (errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.ENOSYS)) {
			return os.Rename(source, dest)
		}
		return fmt.Errorf("保存文件失败: %w", err)
	}
	// Keep the private link until queue completion is persisted, so an interrupted
	// publication is recognized on restart and never overwrites user files.
	return nil
}

func handleDownloads(w http.ResponseWriter, r *http.Request) {
	if downloads == nil {
		writeError(w, 503, "缓存队列未就绪")
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]interface{}{"code": 0, "data": downloads.snapshot()})
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, 405, "仅支持 GET/POST")
		return
	}
	var command struct {
		Action string       `json:"action"`
		ID     string       `json:"id"`
		Task   downloadTask `json:"task"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&command); err != nil {
		writeError(w, 400, "队列参数无效")
		return
	}
	var err error
	if command.Action == "enqueue" {
		err = downloads.enqueue(command.Task)
	} else {
		err = downloads.control(command.Action, command.ID)
	}
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, 200, map[string]interface{}{"code": 0, "data": downloads.snapshot()})
}
