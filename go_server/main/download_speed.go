package main

import "time"

const downloadSpeedInterval = time.Second
const downloadSpeedWindow = 8 * time.Second

type downloadSpeedSample struct {
	at    time.Time
	bytes int64
}

// Sample once per second, including idle seconds. The initial sample excludes
// bytes restored from an earlier session rather than counting them as traffic.
type downloadSpeedMeter struct {
	samples []downloadSpeedSample
}

func (m *downloadSpeedMeter) reset(now time.Time, received int64) {
	m.samples = []downloadSpeedSample{{now, received}}
}

func (m *downloadSpeedMeter) sample(now time.Time, received int64) int64 {
	if len(m.samples) == 0 || received < m.samples[len(m.samples)-1].bytes {
		m.reset(now, received)
		return 0
	}
	if !now.After(m.samples[len(m.samples)-1].at) {
		return 0
	}
	m.samples = append(m.samples, downloadSpeedSample{now, received})
	cutoff := now.Add(-downloadSpeedWindow)
	for len(m.samples) > 2 && !m.samples[1].at.After(cutoff) {
		m.samples = m.samples[1:]
	}
	first := m.samples[0]
	start := first.at
	bytesAtStart := float64(first.bytes)
	if first.at.Before(cutoff) {
		next := m.samples[1]
		fraction := float64(cutoff.Sub(first.at)) / float64(next.at.Sub(first.at))
		bytesAtStart += float64(next.bytes-first.bytes) * fraction
		start = cutoff
	}
	elapsed := now.Sub(start).Seconds()
	if elapsed < downloadSpeedInterval.Seconds() {
		return 0
	}
	return int64((float64(received) - bytesAtStart) / elapsed)
}
