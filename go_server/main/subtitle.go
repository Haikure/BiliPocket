package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
)

func formatAssTime(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	h := int(sec) / 3600
	m := (int(sec) % 3600) / 60
	s := int(sec) % 60
	cs := int((sec - float64(int(sec))) * 100)
	if cs < 0 {
		cs = 0
	}
	if cs > 99 {
		cs = 99
	}
	return fmt.Sprintf("%d:%02d:%02d.%02d", h, m, s, cs)
}

func floatParam(val string, defaultVal float64) (float64, error) {
	if val == "" {
		return defaultVal, nil
	}
	f, err := strconv.ParseFloat(val, 64)
	if err != nil {
		return 0, fmt.Errorf("参数必须为数字，收到: %s", val)
	}
	return f, nil
}

func normalizeSubtitleURL(url string) string {
	if strings.HasPrefix(url, "//") {
		return "https:" + url
	}
	return url
}

func getSubtitleURL(subs []interface{}, sid int) string {
	for _, item := range subs {
		obj, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		matches := false
		for _, key := range []string{"id", "subtitle_id", "id_str"} {
			switch idVal := obj[key].(type) {
			case float64:
				if int(idVal) == sid {
					matches = true
				}
			case string:
				if parsed, err := strconv.Atoi(idVal); err == nil && parsed == sid {
					matches = true
				}
			}
			if matches {
				break
			}
		}
		if matches {
			url, _ := obj["subtitle_url"].(string)
			if url == "" {
				url, _ = obj["url"].(string)
			}
			return normalizeSubtitleURL(url)
		}
	}
	return ""
}

func fetchPlayerSubtitleList(ctx context.Context, client *BilibiliClient, aid, cid int, bvid string) ([]interface{}, error) {
	result, err := client.GetPlayerV2(ctx, aid, cid, bvid)
	if err != nil {
		return nil, err
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(result, &resp); err != nil {
		return nil, fmt.Errorf("字幕列表解析失败")
	}
	code, _ := resp["code"].(float64)
	if int(code) != 0 {
		msg, _ := resp["message"].(string)
		if msg == "" {
			msg = "获取字幕列表失败"
		}
		return nil, errors.New(msg)
	}

	data, _ := resp["data"].(map[string]interface{})
	subtitle, _ := data["subtitle"].(map[string]interface{})
	subs, _ := subtitle["subtitles"].([]interface{})
	return subs, nil
}

func fetchSubtitleBody(ctx context.Context, client *BilibiliClient, subtitleURL string) ([]interface{}, error) {
	bodyRaw, err := client.rawGetURL(ctx, subtitleURL)
	if err != nil {
		return nil, fmt.Errorf("字幕下载失败: %w", err)
	}
	var subResp map[string]interface{}
	if err := json.Unmarshal(bodyRaw, &subResp); err != nil {
		return nil, fmt.Errorf("字幕内容解析失败")
	}
	body, _ := subResp["body"].([]interface{})
	if len(body) == 0 {
		return nil, fmt.Errorf("该字幕内容为空")
	}
	return body, nil
}

func sanitizeASSText(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\\N")
	text = strings.ReplaceAll(text, "\n", "\\N")
	text = strings.ReplaceAll(text, "\r", "\\N")
	// 避免 ASS override block 被字幕正文意外触发。
	text = strings.ReplaceAll(text, "{", "（")
	text = strings.ReplaceAll(text, "}", "）")
	return text
}

func subtitleDisplayWidth(r rune) float64 {
	if r == '\t' {
		return 2
	}
	if r <= unicode.MaxASCII {
		if r == ' ' {
			return 0.5
		}
		if unicode.IsSpace(r) {
			return 0
		}
		return 0.5
	}
	return 1
}

func wrapSubtitleLine(line string, maxWidth float64) []string {
	if line == "" {
		return []string{""}
	}
	if maxWidth <= 0 {
		maxWidth = 24
	}

	lines := make([]string, 0, len(line)/12+1)
	var current strings.Builder
	currentWidth := 0.0

	for _, r := range line {
		width := subtitleDisplayWidth(r)
		if current.Len() > 0 && currentWidth+width > maxWidth {
			lines = append(lines, current.String())
			current.Reset()
			currentWidth = 0
			if unicode.IsSpace(r) {
				continue
			}
		}
		current.WriteRune(r)
		currentWidth += width
	}

	if current.Len() > 0 {
		lines = append(lines, current.String())
	}
	if len(lines) == 0 {
		return []string{""}
	}
	return lines
}

func wrapSubtitleText(text string, maxWidth float64) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")

	rawLines := strings.Split(text, "\n")
	wrappedLines := make([]string, 0, len(rawLines))
	for _, rawLine := range rawLines {
		wrappedLines = append(wrappedLines, wrapSubtitleLine(rawLine, maxWidth)...)
	}
	return strings.Join(wrappedLines, "\n")
}

func subtitleSafeMarginV(fontSize int, marginV int, spacing float64, outlineEnabled bool, outlineWidth int, backgroundEnabled bool) int {
	lineHeight := fontSize + int(spacing+0.999)
	if lineHeight < fontSize {
		lineHeight = fontSize
	}
	minMargin := lineHeight / 3
	if minMargin < 4 {
		minMargin = 4
	}
	if outlineEnabled {
		minMargin += outlineWidth
	}
	if backgroundEnabled {
		minMargin += 2
	}
	if marginV > minMargin {
		return marginV
	}
	return minMargin
}

func subtitleASSColorWithOpacity(rgb string, opacity float64) string {
	if opacity < 0 {
		opacity = 0
	}
	if opacity > 1 {
		opacity = 1
	}
	alpha := 255 - int(opacity*255+0.5)
	return fmt.Sprintf("&H%02X%s", alpha, rgb)
}

func subtitleASSColors(colorPreset string) (primary string, outline string, back string) {
	switch normalizeSubtitleColorPreset(colorPreset) {
	case "yellow":
		return "&H004AD5FF", "&H00404040", "&H88404040"
	case "cyan":
		return "&H00FCD37D", "&H00404040", "&H88404040"
	case "black":
		return "&H00000000", "&H00FFFFFF", "&H88FFFFFF"
	default:
		return "&H00FFFFFF", "&H00404040", "&H88404040"
	}
}

func buildASSFromSubtitleBody(body []interface{}, fontSize int, marginV int, spacing float64, weight int, colorPreset string, outlineEnabled bool, outlineWidth int, backgroundEnabled bool, backgroundOpacity float64) string {
	const (
		playResX         = 320
		playResY         = 170
		sideMargin       = 8
		maxSubtitleWidth = 24.0
	)

	effectiveMarginV := subtitleSafeMarginV(fontSize, marginV, spacing, outlineEnabled, outlineWidth, backgroundEnabled)

	var sb strings.Builder
	sb.WriteString("[Script Info]\n")
	sb.WriteString("ScriptType: v4.00+\n")
	sb.WriteString(fmt.Sprintf("PlayResX: %d\n", playResX))
	sb.WriteString(fmt.Sprintf("PlayResY: %d\n", playResY))
	sb.WriteString("WrapStyle: 2\n")
	sb.WriteString("ScaledBorderAndShadow: no\n\n")
	sb.WriteString("[V4+ Styles]\n")
	sb.WriteString("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n")
	spacingStr := strconv.FormatFloat(spacing, 'f', 1, 64)
	primaryColor, outlineColor, backColor := subtitleASSColors(colorPreset)
	borderStyle := 1
	outline := 0
	if outlineEnabled {
		outline = outlineWidth
	}
	if backgroundEnabled {
		borderStyle = 3
		outlineColor = subtitleASSColorWithOpacity("404040", backgroundOpacity)
		backColor = outlineColor
		outline = 2
	}
	styleLine := fmt.Sprintf("Style: Default,Arial,%d,%s,%s,%s,%s,0,0,0,0,100,100,%s,0,%d,%d,0,2,%d,%d,%d,1\n\n", fontSize, primaryColor, primaryColor, outlineColor, backColor, spacingStr, borderStyle, outline, sideMargin, sideMargin, effectiveMarginV)
	sb.WriteString(styleLine)
	sb.WriteString("[Events]\n")
	sb.WriteString("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")

	for _, item := range body {
		obj, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		from, _ := obj["from"].(float64)
		to, _ := obj["to"].(float64)
		content, _ := obj["content"].(string)
		if to <= from {
			to = from + 2
		}
		wrappedText := wrapSubtitleText(html.UnescapeString(content), maxSubtitleWidth)
		text := sanitizeASSText(wrappedText)
		sb.WriteString(fmt.Sprintf("Dialogue: 0,%s,%s,Default,,0,0,0,,{\\b%d}%s\n", formatAssTime(from), formatAssTime(to), weight, text))
	}

	return sb.String()
}


func handleVideoSubtitleList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := requireIntQuery(w, q, "aid")
	if !ok {
		return
	}
	cid, ok := requireIntQuery(w, q, "cid")
	if !ok {
		return
	}
	bvid := q.Get("bvid")
	subs, err := fetchPlayerSubtitleList(r.Context(), getClient(), aid, cid, bvid)
	if err != nil {
		logError("处理 /video/subtitle/list 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "success",
		"data": map[string]interface{}{
			"subtitles": subs,
		},
	})
}

func handleVideoSubtitleASS(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := requireIntQuery(w, q, "aid")
	if !ok {
		return
	}
	cid, ok := requireIntQuery(w, q, "cid")
	if !ok {
		return
	}
	sid, ok := requireIntQuery(w, q, "sid")
	if !ok {
		return
	}
	bvid := q.Get("bvid")

	fontSize, marginV, spacing, weight, colorPreset, outlineEnabled, outlineWidth, backgroundEnabled, backgroundOpacity, ok := subtitleStyleParamsFromRequest(w, q)
	if !ok {
		return
	}

	client := getClient()
	subtitleURL := normalizeSubtitleURL(q.Get("subtitle_url"))
	if subtitleURL == "" {
		subs, err := fetchPlayerSubtitleList(r.Context(), client, aid, cid, bvid)
		if err != nil {
			logError("处理 /video/subtitle/ass 请求失败: %s", err.Error())
			writeError(w, 500, err.Error())
			return
		}
		subtitleURL = getSubtitleURL(subs, sid)
	}
	if subtitleURL == "" {
		writeError(w, 404, "未找到指定字幕")
		return
	}

	body, err := fetchSubtitleBody(r.Context(), client, subtitleURL)
	if err != nil {
		status := 500
		if err.Error() == "该字幕内容为空" {
			status = 404
		}
		writeError(w, status, err.Error())
		return
	}

	assContent := buildASSFromSubtitleBody(body, fontSize, marginV, spacing, weight, colorPreset, outlineEnabled, outlineWidth, backgroundEnabled, backgroundOpacity)
	tmpPath := filepath.Join(os.TempDir(), fmt.Sprintf("bili_cc_%d_%d_%d.ass", aid, cid, sid))
	if err := os.WriteFile(tmpPath, []byte(assContent), 0644); err != nil {
		writeError(w, 500, "字幕文件写入失败")
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "success",
		"data": map[string]interface{}{
			"path": tmpPath,
		},
	})
}

func handleVideoSubtitleASSFile(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := requireIntQuery(w, q, "aid")
	if !ok {
		return
	}
	cid, ok := requireIntQuery(w, q, "cid")
	if !ok {
		return
	}
	sid, ok := requireIntQuery(w, q, "sid")
	if !ok {
		return
	}
	bvid := q.Get("bvid")

	fontSize, marginV, spacing, weight, colorPreset, outlineEnabled, outlineWidth, backgroundEnabled, backgroundOpacity, ok := subtitleStyleParamsFromRequest(w, q)
	if !ok {
		return
	}

	client := getClient()
	subtitleURL := normalizeSubtitleURL(q.Get("subtitle_url"))
	if subtitleURL == "" {
		subs, err := fetchPlayerSubtitleList(r.Context(), client, aid, cid, bvid)
		if err != nil {
			logError("处理 /video/subtitle/ass/file 请求失败: %s", err.Error())
			writeError(w, 500, err.Error())
			return
		}
		subtitleURL = getSubtitleURL(subs, sid)
	}
	if subtitleURL == "" {
		writeError(w, 404, "未找到指定字幕")
		return
	}

	body, err := fetchSubtitleBody(r.Context(), client, subtitleURL)
	if err != nil {
		status := 500
		if err.Error() == "该字幕内容为空" {
			status = 404
		}
		writeError(w, status, err.Error())
		return
	}

	assContent := buildASSFromSubtitleBody(body, fontSize, marginV, spacing, weight, colorPreset, outlineEnabled, outlineWidth, backgroundEnabled, backgroundOpacity)
	w.Header().Set("Content-Type", "application/x-ass; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=\"bili_cc_%d_%d_%d.ass\"", aid, cid, sid))
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, assContent)
}
