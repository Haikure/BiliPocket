package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Eyevinn/mp4ff/mp4"
)

// ==================== DASH m4s → 单个 mp4 合并 ====================

const mergeDownloadDir = "/userdisk/Music/bili"

// handleVideoMerge: GET /video/merge?video_path=..&audio_path=..&output_path=..
// 将 B 站下载的两条单轨 DASH m4s（fMP4）合并为单个双轨 .mp4。
// 惰性 mdat + 流式拷贝，内存有界；输出为 fMP4（ftyp + moov + 按时间戳交错的 moof/mdat）。
func handleVideoMerge(w http.ResponseWriter, r *http.Request) {
	// 合并耗时可能远超 60s 写超时，清除本请求的写超时
	if err := http.NewResponseController(w).SetWriteDeadline(time.Time{}); err != nil {
		logWarn("清除合并请求写超时失败: %s", err.Error())
	}

	videoPath, err := validateMergePath(mergeDownloadDir, r.URL.Query().Get("video_path"), ".m4s")
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	audioPath, err := validateMergePath(mergeDownloadDir, r.URL.Query().Get("audio_path"), ".m4s")
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	outputPath, err := validateMergePath(mergeDownloadDir, r.URL.Query().Get("output_path"), ".mp4")
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// 按输出路径互斥，拒绝并发写同一文件
	unlock, err := acquireMergeLock(outputPath)
	if err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	defer unlock()

	// 输入必须存在且为普通文件，输出必须不存在
	for _, p := range []string{videoPath, audioPath} {
		fi, err := os.Stat(p)
		if err != nil || !fi.Mode().IsRegular() {
			writeError(w, http.StatusBadRequest, "输入文件不存在: "+p)
			return
		}
	}
	if _, err := os.Stat(outputPath); err == nil {
		writeError(w, http.StatusConflict, "输出文件已存在: "+outputPath)
		return
	}

	// 磁盘空间预检：合并期间 m4s 与 mp4 并存，约需 2× 输入总大小
	var totalIn int64
	for _, p := range []string{videoPath, audioPath} {
		if fi, err := os.Stat(p); err == nil {
			totalIn += fi.Size()
		}
	}
	free, err := diskFreeBytes(mergeDownloadDir)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "磁盘空间检查失败: "+err.Error())
		return
	}
	if uint64(totalIn)*2 > free {
		writeError(w, http.StatusInsufficientStorage, "磁盘空间不足，无法合并")
		return
	}

	// 先写 .part 再原子 rename，避免进程被杀残留看似完整的损坏 mp4
	tmpPath := outputPath + ".part"
	_ = os.Remove(tmpPath) // 清理上次中断残留
	if err := mergeM4s(r.Context(), videoPath, audioPath, tmpPath); err != nil {
		os.Remove(tmpPath) // 清理半成品
		writeError(w, http.StatusInternalServerError, "合并失败: "+err.Error())
		return
	}

	// rename 前复查输出不存在（防竞态覆盖）
	if _, err := os.Stat(outputPath); err == nil {
		os.Remove(tmpPath)
		writeError(w, http.StatusConflict, "输出文件已存在: "+outputPath)
		return
	}
	if err := os.Rename(tmpPath, outputPath); err != nil {
		os.Remove(tmpPath)
		writeError(w, http.StatusInternalServerError, "合并结果落盘失败: "+err.Error())
		return
	}

	size := int64(0)
	if fi, err := os.Stat(outputPath); err == nil {
		size = fi.Size()
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"code":    0,
		"message": "合并完成",
		"data": map[string]interface{}{
			"output_path": outputPath,
			"size":        size,
		},
	})
}

// ==================== 合并并发保护 ====================

var (
	mergeLocksMu sync.Mutex
	mergeLocks   = map[string]*mergePathLock{}
)

type mergePathLock struct {
	mu       sync.Mutex
	refCount int
}

// acquireMergeLock 按输出路径互斥，已有任务进行中则报错。
// refCount 计入所有在途调用（含失败者），归零才删条目：持有者始终占一个引用，
// 避免"解锁后、删除前"的空窗里新调用与旧任务并发写同一路径。
func acquireMergeLock(outputPath string) (func(), error) {
	mergeLocksMu.Lock()
	l, ok := mergeLocks[outputPath]
	if !ok {
		l = &mergePathLock{}
		mergeLocks[outputPath] = l
	}
	l.refCount++
	mergeLocksMu.Unlock()

	if !l.mu.TryLock() {
		// 本调用未持有锁，只归还引用计数，不能 Unlock
		mergeLocksMu.Lock()
		l.refCount--
		if l.refCount == 0 {
			delete(mergeLocks, outputPath)
		}
		mergeLocksMu.Unlock()
		return nil, errors.New("该文件的合并任务正在进行中，请稍后重试")
	}
	return func() { releaseMergeLock(l, outputPath) }, nil
}

func releaseMergeLock(l *mergePathLock, outputPath string) {
	l.mu.Unlock()
	mergeLocksMu.Lock()
	l.refCount--
	if l.refCount == 0 {
		delete(mergeLocks, outputPath)
	}
	mergeLocksMu.Unlock()
}

// validateMergePath 校验路径位于 root 目录内且后缀符合白名单，返回净化后的绝对路径。
func validateMergePath(root, p, allowedExt string) (string, error) {
	if p == "" {
		return "", errors.New("缺少路径参数")
	}
	clean := filepath.Clean(p)
	rel, err := filepath.Rel(root, clean)
	if err != nil {
		return "", errors.New("路径无效")
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("路径不在下载目录内")
	}
	if strings.ToLower(filepath.Ext(clean)) != allowedExt {
		return "", fmt.Errorf("文件类型不允许: %s（需要 %s）", filepath.Ext(clean), allowedExt)
	}
	// 从 root 逐级 Lstat 防符号链接逃逸；输出文件尚不存在时允许最后一级缺失
	cur := root
	for _, comp := range strings.Split(rel, string(filepath.Separator)) {
		if comp == "" || comp == "." {
			continue
		}
		cur = filepath.Join(cur, comp)
		fi, err := os.Lstat(cur)
		if err != nil {
			if os.IsNotExist(err) && comp == filepath.Base(rel) {
				break // 输出文件尚不存在属正常
			}
			return "", errors.New("路径无效")
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("路径包含符号链接，已拒绝")
		}
	}
	return clean, nil
}

func diskFreeBytes(dir string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return st.Bavail * uint64(st.Bsize), nil
}

// decodedM4s 持有惰性解码的 m4s 及其文件句柄（mdat 数据按需从文件读取）。
type decodedM4s struct {
	f    *mp4.File
	file *os.File
}

func decodeM4s(path string) (*decodedM4s, error) {
	fh, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	f, err := mp4.DecodeFile(fh,
		mp4.WithDecodeMode(mp4.DecModeLazyMdat),
		mp4.WithDecodeFlags(mp4.DecStartOnMoof))
	if err != nil {
		fh.Close()
		return nil, err
	}
	return &decodedM4s{f: f, file: fh}, nil
}

// mergeM4s 把两条单轨 fMP4 合并为单文件双轨 fMP4。
// ctx 取消时尽早返回（客户端断开后不继续做无谓的磁盘 IO）。
func mergeM4s(ctx context.Context, videoPath, audioPath, outputPath string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	v, err := decodeM4s(videoPath)
	if err != nil {
		return fmt.Errorf("解析视频流失败: %w", err)
	}
	defer v.file.Close()

	a, err := decodeM4s(audioPath)
	if err != nil {
		return fmt.Errorf("解析音频流失败: %w", err)
	}
	defer a.file.Close()

	if len(v.f.Moov.Traks) != 1 || len(a.f.Moov.Traks) != 1 {
		return errors.New("m4s 必须为单轨文件")
	}
	if len(v.f.Segments) == 0 || len(a.f.Segments) == 0 {
		return errors.New("m4s 不包含媒体分片")
	}

	vTrak := v.f.Moov.Traks[0]
	aTrak := a.f.Moov.Traks[0]

	// 1. 收集全部分片，带解码时间（毫秒），用于全局时间交错
	type fragItem struct {
		src    *decodedM4s
		frag   *mp4.Fragment
		timeMs int64
	}
	var items []fragItem
	var videoEndTs, audioEndTs uint64 // 各轨最后样本结束的解码时间（各自 timescale）
	collect := func(d *decodedM4s, trak *mp4.TrakBox, dst *uint64) error {
		timescale := trak.Mdia.Mdhd.Timescale
		if timescale == 0 {
			return errors.New("轨道 timescale 为 0")
		}
		var trex *mp4.TrexBox
		if d.f.Moov.Mvex != nil {
			trex, _ = d.f.Moov.Mvex.GetTrex(trak.Tkhd.TrackID)
		}
		for _, seg := range d.f.Segments {
			if err := ctx.Err(); err != nil {
				return err
			}
			for _, frag := range seg.Fragments {
				if frag.Moof == nil || len(frag.Moof.Trafs) == 0 {
					continue
				}
				tfdt := frag.Moof.Trafs[0].Tfdt
				if tfdt == nil {
					return errors.New("分片缺少 tfdt")
				}
				base := tfdt.BaseMediaDecodeTime()
				var endTs uint64 = base
				for _, trun := range frag.Moof.Trafs[0].Truns {
					endTs += trunTotalDur(trun, frag.Moof.Trafs[0].Tfhd, trex)
				}
				if endTs > *dst {
					*dst = endTs
				}
				items = append(items, fragItem{src: d, frag: frag, timeMs: int64(base) * 1000 / int64(timescale)})
			}
		}
		return nil
	}
	if err := collect(v, vTrak, &videoEndTs); err != nil {
		return err
	}
	if err := collect(a, aTrak, &audioEndTs); err != nil {
		return err
	}
	if len(items) == 0 {
		return errors.New("未找到可合并的分片")
	}

	// 按解码时间全局排序；同一时刻视频分片在前
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].timeMs != items[j].timeMs {
			return items[i].timeMs < items[j].timeMs
		}
		vi := items[i].src == v
		vj := items[j].src == v
		return vi && !vj
	})

	// 2. 合并 init：ftyp + 视频 moov，追加音频 trak/trex；trackID 视频=1、音频=2
	vSrcID := vTrak.Tkhd.TrackID
	aSrcID := aTrak.Tkhd.TrackID

	if v.f.Moov.Mvex == nil {
		v.f.Moov.Mvex = mp4.NewMvexBox()
		v.f.Moov.AddChild(v.f.Moov.Mvex)
	}
	removeMehd(v.f.Moov.Mvex)

	if trex, ok := v.f.Moov.Mvex.GetTrex(vSrcID); ok {
		trex.TrackID = 1
	} else {
		v.f.Moov.Mvex.AddChild(mp4.CreateTrex(1))
	}
	vTrak.Tkhd.TrackID = 1

	aTrex := (*mp4.TrexBox)(nil)
	if a.f.Moov.Mvex != nil {
		aTrex, _ = a.f.Moov.Mvex.GetTrex(aSrcID)
	}
	if aTrex != nil {
		aTrex.TrackID = 2
		v.f.Moov.Mvex.AddChild(aTrex)
	} else {
		v.f.Moov.Mvex.AddChild(mp4.CreateTrex(2))
	}
	aTrak.Tkhd.TrackID = 2

	v.f.Moov.AddChild(aTrak) // 追加音频 trak（自动聚到 trak 群中）
	if v.f.Moov.Mvhd != nil {
		v.f.Moov.Mvhd.NextTrackID = 3
		// 更新 mvhd 时长为两轨结束时间的较大者（换算到视频 timescale）
		vts := v.f.Moov.Mvhd.Timescale
		if vts == 0 {
			vts = vTrak.Mdia.Mdhd.Timescale
		}
		dur := videoEndTs
		if ats := aTrak.Mdia.Mdhd.Timescale; ats != 0 {
			if aEnd := audioEndTs * uint64(vts) / uint64(ats); aEnd > dur {
				dur = aEnd
			}
		}
		v.f.Moov.Mvhd.Duration = dur
	}

	init := mp4.NewMP4Init()
	if v.f.Ftyp != nil {
		init.AddChild(v.f.Ftyp)
	}
	init.AddChild(v.f.Moov)

	// 3. 写出合并后的 init + 按时间交错的各分片
	out, err := os.Create(outputPath)
	if err != nil {
		return err
	}
	defer out.Close()

	if err := init.Encode(out); err != nil {
		return fmt.Errorf("写入 init 失败: %w", err)
	}

	seq := uint32(1)
	for _, it := range items {
		if err := ctx.Err(); err != nil {
			return err
		}
		newTrackID := uint32(1)
		if it.src != v {
			newTrackID = 2
		}
		if err := writeFragment(out, it.src.file, it.frag, newTrackID, seq); err != nil {
			return err
		}
		seq++
	}
	return nil
}

func removeMehd(mvex *mp4.MvexBox) {
	mvex.Mehd = nil
	out := mvex.Children[:0]
	for _, c := range mvex.Children {
		if c.Type() != "mehd" {
			out = append(out, c)
		}
	}
	mvex.Children = out
}

// trunTotalDur 计算单个 trun 的总样本时长（轨道 timescale 单位）。
// 不复用 trun.AddSampleDefaultValues：它会改写样本默认值，影响后续 moof 重编码结果。
func trunTotalDur(trun *mp4.TrunBox, tfhd *mp4.TfhdBox, trex *mp4.TrexBox) uint64 {
	if trun.HasSampleDuration() {
		var total uint64
		for _, s := range trun.Samples {
			total += uint64(s.Dur)
		}
		return total
	}
	def := uint32(0)
	if tfhd.HasDefaultSampleDuration() {
		def = tfhd.DefaultSampleDuration
	} else if trex != nil {
		def = trex.DefaultSampleDuration
	}
	return uint64(def) * uint64(trun.SampleCount())
}

// writeFragment 重写并写出单个分片：mfhd 序号、tfhd 轨道 ID、default-base-is-moof 补齐，mdat 载荷流式拷贝。
func writeFragment(w io.Writer, src io.ReadSeeker, frag *mp4.Fragment, trackID, seq uint32) error {
	if len(frag.Moof.Trafs) != 1 {
		return fmt.Errorf("分片含 %d 个 traf，仅支持单 traf", len(frag.Moof.Trafs))
	}
	traf := frag.Moof.Trafs[0]
	if traf.Tfhd == nil {
		return errors.New("分片缺少 tfhd")
	}
	if frag.Moof.Mfhd == nil {
		return errors.New("分片缺少 mfhd")
	}

	frag.Moof.Mfhd.SequenceNumber = seq
	traf.Tfhd.TrackID = trackID

	// 偏移相对 moof 起点：moof 重写后位置不变、偏移依然有效，只需补 default-base-is-moof 标志
	if !traf.Tfhd.DefaultBaseIfMoof() {
		if traf.Tfhd.HasBaseDataOffset() {
			return errors.New("不支持的 tfhd base_data_offset")
		}
		traf.Tfhd.Flags |= mp4.TfhdDefaultBaseIsMoofFlag
	}

	// moof 重编码到内存并校验大小不变（偏移相对 moof 起始才保持有效）
	var buf bytes.Buffer
	if err := frag.Moof.Encode(&buf); err != nil {
		return fmt.Errorf("重编码 moof 失败: %w", err)
	}
	if uint64(buf.Len()) != frag.Moof.Size() {
		return fmt.Errorf("moof 重编码后大小变化 %d -> %d", frag.Moof.Size(), buf.Len())
	}
	if _, err := w.Write(buf.Bytes()); err != nil {
		return err
	}

	// mdat 头惰性写出，载荷从源文件按绝对偏移流式拷贝
	if frag.Mdat != nil {
		if err := frag.Mdat.Encode(w); err != nil {
			return fmt.Errorf("写入 mdat 头失败: %w", err)
		}
		if frag.Mdat.IsLazy() {
			start := int64(frag.Mdat.PayloadAbsoluteOffset())
			size := int64(frag.Mdat.GetLazyDataSize())
			if _, err := frag.Mdat.CopyData(start, size, src, w); err != nil {
				return fmt.Errorf("拷贝 mdat 失败: %w", err)
			}
		}
	}
	return nil
}
