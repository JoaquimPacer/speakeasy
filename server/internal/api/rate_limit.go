package api

import (
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxFixedWindowLiveKeys = 10_000

type fixedWindowEntry struct {
	count   int
	resetAt time.Time
}

type fixedWindowLimiter struct {
	mu        sync.Mutex
	limit     int
	window    time.Duration
	maxKeys   int
	entries   map[string]fixedWindowEntry
	lastSweep time.Time
}

func newFixedWindowLimiter(limit int, window time.Duration) *fixedWindowLimiter {
	return newFixedWindowLimiterWithMaxKeys(limit, window, maxFixedWindowLiveKeys)
}

func newFixedWindowLimiterWithMaxKeys(limit int, window time.Duration, maxKeys int) *fixedWindowLimiter {
	return &fixedWindowLimiter{
		limit:   limit,
		window:  window,
		maxKeys: maxKeys,
		entries: make(map[string]fixedWindowEntry),
	}
}

func (l *fixedWindowLimiter) allow(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	allowed, retryAfter := l.canAllowLocked(key, now)
	if !allowed {
		return false, retryAfter
	}
	l.recordLocked(key, now)
	return true, 0
}

func (l *fixedWindowLimiter) canAllowLocked(key string, now time.Time) (bool, time.Duration) {
	if l.lastSweep.IsZero() || now.Sub(l.lastSweep) >= l.window {
		l.sweepExpiredLocked(now)
	}

	entry, ok := l.entries[key]
	if ok && !now.Before(entry.resetAt) {
		delete(l.entries, key)
		ok = false
	}
	if !ok {
		if len(l.entries) >= l.maxKeys {
			// A normal periodic sweep may have run recently, but capacity must be
			// checked against live keys. Never evict a live counter because doing
			// so would let that key reset its allowance early.
			l.sweepExpiredLocked(now)
		}
		if len(l.entries) >= l.maxKeys {
			return false, l.earliestResetLocked(now)
		}
		return true, 0
	}
	if entry.count >= l.limit {
		return false, entry.resetAt.Sub(now)
	}
	return true, 0
}

func (l *fixedWindowLimiter) recordLocked(key string, now time.Time) {
	entry, ok := l.entries[key]
	if !ok || !now.Before(entry.resetAt) {
		l.entries[key] = fixedWindowEntry{count: 1, resetAt: now.Add(l.window)}
		return
	}
	entry.count++
	l.entries[key] = entry
}

func (l *fixedWindowLimiter) sweepExpiredLocked(now time.Time) {
	for key, entry := range l.entries {
		if !now.Before(entry.resetAt) {
			delete(l.entries, key)
		}
	}
	l.lastSweep = now
}

func (l *fixedWindowLimiter) earliestResetLocked(now time.Time) time.Duration {
	var earliest time.Time
	for _, entry := range l.entries {
		if earliest.IsZero() || entry.resetAt.Before(earliest) {
			earliest = entry.resetAt
		}
	}
	if earliest.IsZero() || !now.Before(earliest) {
		return l.window
	}
	return earliest.Sub(now)
}

func (s *Server) allowRate(w http.ResponseWriter, limiter *fixedWindowLimiter, key string) bool {
	allowed, retryAfter := limiter.allow(key, s.now().UTC())
	if allowed {
		return true
	}
	writeRateLimitExceeded(w, retryAfter)
	return false
}

func writeRateLimitExceeded(w http.ResponseWriter, retryAfter time.Duration) {
	seconds := int64(math.Ceil(retryAfter.Seconds()))
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.FormatInt(seconds, 10))
	http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
}

// allowScopedThenGlobal ensures a caller that has already exhausted its scoped
// allowance cannot consume the shared process-wide allowance with rejected
// requests.
func (s *Server) allowScopedThenGlobal(
	w http.ResponseWriter,
	scoped *fixedWindowLimiter,
	scopedKey string,
	global *fixedWindowLimiter,
) bool {
	if scoped == global {
		return s.allowRate(w, scoped, scopedKey)
	}

	now := s.now().UTC()
	// Every paired call locks in scoped/global order. Holding both locks makes
	// admission transactional: neither allowance is consumed unless both
	// checks pass, and a globally rejected new scope never allocates a key.
	scoped.mu.Lock()
	global.mu.Lock()

	allowed, retryAfter := scoped.canAllowLocked(scopedKey, now)
	if allowed {
		allowed, retryAfter = global.canAllowLocked("global", now)
	}
	if allowed {
		scoped.recordLocked(scopedKey, now)
		global.recordLocked("global", now)
	}

	global.mu.Unlock()
	scoped.mu.Unlock()

	if !allowed {
		writeRateLimitExceeded(w, retryAfter)
	}
	return allowed
}

func (s *Server) clientIP(r *http.Request) string {
	if s.options.TrustProxyHeaders {
		// The deployment flag is enabled only when the relay's published port is
		// bound to host loopback and the reverse proxy overwrites X-Real-IP. This
		// value therefore wins over the append-style X-Forwarded-For chain.
		if realIP := normalizedIP(r.Header.Get("X-Real-IP")); realIP != "" {
			return realIP
		}
		// A conforming proxy appends the address it directly observed. Never use
		// the spoofable leftmost entry supplied by an untrusted client.
		forwarded := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
		for index := len(forwarded) - 1; index >= 0; index-- {
			if forwardedIP := normalizedIP(forwarded[index]); forwardedIP != "" {
				return forwardedIP
			}
		}
	}

	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil {
		if direct := normalizedIP(host); direct != "" {
			return direct
		}
	}
	if direct := normalizedIP(r.RemoteAddr); direct != "" {
		return direct
	}
	return "unknown"
}

func normalizedIP(value string) string {
	parsed := net.ParseIP(strings.TrimSpace(value))
	if parsed == nil {
		return ""
	}
	return parsed.String()
}
